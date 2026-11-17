import Foundation
import TranscribeKit
import AVFoundation
import AudioToolbox
import ScreenCaptureKit
import CoreAudio
import AppKit

/// Captures all system audio output using ScreenCaptureKit (macOS 13+),
/// optionally mixed with microphone input for recording both sides of a conversation.
///
/// Two phases share one `SCStream`:
/// 1. **Monitoring** (`startMonitoring`): the stream runs for the level meter
///    only. Starting it triggers the macOS permission prompt on first use.
/// 2. **Recording** (`startCapture`): the same buffers are also encoded to AAC
///    in an `.m4a` file and fed to live transcription.
///
/// When the microphone is included, an AVAudioEngine captures it, resamples it
/// to 48kHz stereo, and feeds a ring buffer. The SCStream callback reads from the
/// ring buffer and mixes mic audio with system audio before writing to file.
///
/// The microphone is bound on the engine's own audio unit. The system-wide
/// default input device is never changed, so the call being recorded (Teams
/// or Zoom on "system default") is unaffected by what is picked here.
///
/// This class is main-actor state. Everything the two audio threads touch
/// lives in `SystemAudioMixer`, and the recorded duration is counted in frames
/// written rather than wall-clock time (so sleep and stream restarts never
/// inflate it). The microphone engine is built, started and stopped in the
/// background: its input node is never touched on the main thread.
@MainActor
final class SystemAudioCaptureService: ObservableObject {
    // MARK: - Published State

    @Published private(set) var isMonitoring = false
    @Published private(set) var isCapturing = false
    @Published private(set) var hasRecording = false
    @Published private(set) var isPausedForSleep = false
    /// Seconds of audio written to the current (or last) recording.
    @Published private(set) var recordedSeconds: TimeInterval = 0
    @Published private(set) var recordingURL: URL?
    /// 0…1, mapped from −60…0 dBFS.
    @Published private(set) var systemAudioLevel: Float = 0
    @Published private(set) var micLevel: Float = 0
    /// macOS has not allowed this app to record the screen and system audio.
    @Published private(set) var permissionDenied = false
    @Published var errorMessage: String?

    /// Whether the microphone is mixed into recordings; set it with
    /// `setMicrophoneIncluded(_:)`. Turned off again if the microphone fails.
    @Published private(set) var includesMicrophone = false
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    /// Name of the device the system currently uses by default.
    @Published private(set) var defaultDeviceName: String = ""
    /// `nil` follows the system default input device.
    @Published var selectedMicDeviceID: AudioDeviceID? {
        didSet {
            guard selectedMicDeviceID != oldValue else { return }
            restartMicKeepingRecording()
        }
    }

    // MARK: - Private State

    private let mixer = SystemAudioMixer()

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    /// A stream that is being opened; later callers wait for the same one.
    private var streamStart: Task<Bool, Never>?
    /// Bumped whenever the stream is torn down, so one that was still
    /// starting discards itself instead of being installed.
    private var streamGeneration = 0
    private var isStartingCapture = false

    private var micEngine: AVAudioEngine?
    /// The engine start in flight, if any; `true` when it produced a running engine.
    private var micStart: Task<Bool, Never>?
    /// Bumped whenever the wanted engine changes, so a slow start that has
    /// been superseded discards its result, and readings still queued from
    /// an old tap are ignored.
    private var micGeneration = 0
    private var micConfigurationObserver: NSObjectProtocol?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// Monitoring was running (or starting) when the system went to sleep.
    private var resumeAfterWake = false
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    init() {
        refreshInputDevices()
        observeHardware()
        observeSleep()
    }

    isolated deinit {
        releaseMicEngine()
        removeHardwareObservers()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        _ = mixer.endRecording()
        if let stream {
            Task.detached { try? await stream.stopCapture() }
        }
    }

    // MARK: - Phase 1: Monitoring (level meters)

    /// Starts the stream (and the microphone, if included) so the level
    /// meters move. Safe to call repeatedly. The microphone comes up in the
    /// background and reports its own failure.
    /// - Returns: false if the stream could not be started; `permissionDenied`
    ///   or `errorMessage` says why.
    @discardableResult
    func startMonitoring() async -> Bool {
        guard await ensureStream() else { return false }
        if includesMicrophone, micEngine == nil, micStart == nil {
            launchMicEngine(reportFailure: true)
        }
        return true
    }

    /// Stops the stream and the microphone. A recording in progress is
    /// finalised first.
    func stopMonitoring() {
        resumeAfterWake = false
        if isCapturing { stopCapture() }
        tearDownMicEngine()
        tearDownStream()
    }

    /// Makes sure the stream is running, opening it if necessary.
    private func ensureStream() async -> Bool {
        if isMonitoring { return true }
        guard !Task.isCancelled else { return false }
        let generation = streamGeneration
        let start = streamStart ?? Task { await openStream(generation: generation) }
        streamStart = start
        let opened = await start.value
        // Monitoring can have been stopped again by the time this resumes
        return opened && isMonitoring
    }

    private func openStream(generation: Int) async -> Bool {
        defer {
            if generation == streamGeneration { streamStart = nil }
        }
        do {
            let (newStream, output) = try await makeStream()
            try await newStream.startCapture()

            // The stream was torn down while this one was starting up (the
            // user left the screen, the system went to sleep): stop the fresh
            // stream instead of leaking a live capture nobody will stop.
            guard generation == streamGeneration else {
                try? await newStream.stopCapture()
                return false
            }
            stream = newStream
            streamOutput = output
            isMonitoring = true
            permissionDenied = false
            return true
        } catch {
            guard generation == streamGeneration else { return false }
            if Self.isPermissionFailure(error) {
                permissionDenied = true
            } else {
                errorMessage = String(format: localized("system_audio_start_failed"), error.localizedDescription)
            }
            return false
        }
    }

    /// Builds a fresh SCStream + output for system audio capture.
    private func makeStream() async throws -> (SCStream, StreamOutput) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        guard let display = content.displays.first else {
            throw StreamError.noDisplayFound
        }

        let selfApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let excludedApps = selfApp.map { [$0] } ?? []
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(SystemAudioMixer.sampleRate)
        config.channelCount = SystemAudioMixer.channelCount
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let output = StreamOutput(mixer: mixer, service: self)
        let newStream = SCStream(filter: filter, configuration: config, delegate: output)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.transcribe.systemAudioCapture", qos: .userInteractive))

        return (newStream, output)
    }

    /// Stops the stream, and abandons one that is still being opened, but
    /// leaves any recording file open.
    private func tearDownStream() {
        streamGeneration += 1
        streamStart = nil
        let streamToStop = stream
        stream = nil
        streamOutput = nil
        isMonitoring = false
        systemAudioLevel = 0
        if let streamToStop {
            Task.detached { try? await streamToStop.stopCapture() }
        }
    }

    /// Without permission ScreenCaptureKit fails with `userDeclined` — also
    /// the very first time, while macOS is still showing its own prompt.
    private static func isPermissionFailure(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userDeclined.rawValue {
            return true
        }
        return !CGPreflightScreenCaptureAccess()
    }

    /// Publishes what the stream's sample queue measured for one buffer.
    fileprivate func apply(_ reading: SystemAudioMixer.Reading, from output: StreamOutput) {
        // A buffer still queued from a stream that has since been replaced
        guard output === streamOutput else { return }
        systemAudioLevel = reading.level
        if isCapturing, let frames = reading.framesWritten {
            recordedSeconds = Double(frames) / SystemAudioMixer.sampleRate
        }
        if reading.writeFailed {
            handleWriteFailure()
        }
    }

    /// The stream ended without being asked to: "Stop Sharing" in the menu
    /// bar, the captured display went away, or an internal failure.
    fileprivate func streamDidStop(_ output: StreamOutput) {
        // Only the stream in use counts. One that was already stopped or
        // replaced (sleep/wake, leaving the screen) reports here too, late,
        // and must not end the recording running on its successor.
        guard output === streamOutput else { return }
        let wasCapturing = isCapturing
        // Finalise first so the audio captured so far stays usable
        if wasCapturing { stopCapture() }
        stream = nil
        streamOutput = nil
        isMonitoring = false
        systemAudioLevel = 0
        // Nothing to mix into any more: don't leave the microphone open.
        // `includesMicrophone` stays, so the next recording brings it back.
        tearDownMicEngine()
        if wasCapturing {
            errorMessage = localized("system_audio_capture_interrupted")
        }
    }

    // MARK: - Phase 2: Recording

    /// Starts writing system audio (and the microphone, if included) to a new
    /// temporary file. Starts monitoring first if it isn't running — it may
    /// have been stopped from the menu bar, or never have started.
    /// - Returns: false if recording could not start; `permissionDenied` or
    ///   `errorMessage` says why.
    @discardableResult
    func startCapture() async -> Bool {
        guard !isCapturing, !isStartingCapture else { return false }
        isStartingCapture = true
        defer { isStartingCapture = false }
        errorMessage = nil

        guard await ensureStream() else { return false }

        if includesMicrophone, micEngine?.isRunning != true {
            // The microphone was asked for but isn't delivering. Wait for a
            // start already under way, or begin one, and refuse to record a
            // meeting without the user's voice if it doesn't come up.
            if micEngine != nil { tearDownMicEngine() }
            if micStart == nil { launchMicEngine(reportFailure: false) }
            // A start can be replaced by another while it runs (the hardware
            // changed again): wait until none is left.
            while let start = micStart {
                _ = await start.value
            }
            // Still wanted? The option can be turned off while this waits.
            if includesMicrophone, micEngine == nil {
                errorMessage = localized("system_audio_mic_not_started")
                return false
            }
        }
        // The screen can have gone away while the microphone was starting
        guard isMonitoring, !isCapturing else { return false }

        let url = Self.recordingsDirectory().appendingPathComponent("system_recording_\(UUID().uuidString).m4a")
        do {
            let file = try SystemAudioMixer.makeRecordingFile(at: url)
            mixer.beginRecording(file: file)
        } catch {
            errorMessage = String(format: localized("system_audio_start_failed"), error.localizedDescription)
            return false
        }

        recordingURL = url
        recordedSeconds = 0
        hasRecording = false
        isCapturing = true
        return true
    }

    /// Finalises the recording file. Monitoring keeps running for the meters.
    func stopCapture() {
        guard isCapturing else { return }
        // Returns once any write in progress is done and the file is closed,
        // so the .m4a is complete before `hasRecording` is published.
        let frames = mixer.endRecording()
        isCapturing = false
        isPausedForSleep = false
        recordedSeconds = Double(frames) / SystemAudioMixer.sampleRate

        if frames > 0, let url = recordingURL, FileManager.default.fileExists(atPath: url.path) {
            hasRecording = true
        } else {
            // Nothing was captured: don't offer an empty file for transcription
            discardRecordingFile()
            if errorMessage == nil {
                errorMessage = localized("recording_empty")
            }
        }
    }

    func deleteRecording() {
        if isCapturing {
            _ = mixer.endRecording()
            isCapturing = false
            isPausedForSleep = false
        }
        discardRecordingFile()
        recordedSeconds = 0
    }

    private func discardRecordingFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        hasRecording = false
    }

    private func handleWriteFailure() {
        guard isCapturing else { return }
        stopCapture()
        errorMessage = localized("recording_write_failed")
    }

    // MARK: - Live feed

    /// Receives the recording (system audio plus microphone) as 16 kHz mono
    /// samples while a recording is being written, about 100 ms at a time.
    /// Called on the stream's sample queue; pass `nil` to stop.
    func setLiveSink(_ sink: (@Sendable ([Float]) -> Void)?) {
        mixer.setLiveSink(sink)
    }

    // MARK: - Microphone

    /// Turns mixing the microphone into recordings on or off, also while a
    /// recording is running. Does nothing unless macOS has already allowed
    /// the microphone: opening it without permission is what makes macOS
    /// prompt, so the screen asks first.
    func setMicrophoneIncluded(_ included: Bool) {
        guard included != includesMicrophone else { return }
        if !included {
            includesMicrophone = false
            tearDownMicEngine()
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        includesMicrophone = true
        // Without a stream there is nothing to mix into yet; the microphone
        // then starts together with it.
        if isMonitoring {
            launchMicEngine(reportFailure: true)
        }
    }

    /// Builds and starts a microphone engine off the main actor.
    ///
    /// Opening the input device talks to the audio server, which can take a
    /// while (Bluetooth devices) and blocks outright while macOS is showing
    /// its microphone-permission dialog; on the main thread that freezes the
    /// window.
    @discardableResult
    private func launchMicEngine(reportFailure: Bool) -> Task<Bool, Never> {
        micGeneration += 1
        let generation = micGeneration

        guard AVAudioApplication.shared.recordPermission == .granted else {
            if reportFailure { microphoneFailed() }
            return Task { false }
        }

        // Looked up now rather than taken from `inputDevices`: when a device
        // is unplugged, the engine's notification can arrive before the
        // device list has been refreshed. A selected device that is gone
        // falls back to the system default rather than failing the recording.
        let deviceID = selectedMicDeviceID.flatMap { id in
            Self.enumerateInputDevices().contains { $0.id == id } ? id : nil
        }
        let mixer = self.mixer
        let onReading: @Sendable (SystemAudioMixer.MicrophoneReading) -> Void = { [weak self] reading in
            DispatchQueue.main.async {
                self?.apply(reading, generation: generation)
            }
        }
        // The engine stops itself when the input hardware changes (device
        // unplugged, AirPods connected, sample rate switched). Rebuild it,
        // with a converter for the new format, so the microphone stays in the
        // recording instead of silently dropping out of it.
        let onConfigurationChange: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.micGeneration == generation else { return }
                self.restartMicKeepingRecording()
            }
        }

        let task = Task { [weak self] () -> Bool in
            let result: Result<MicEngineBox, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try Self.makeRunningMicEngine(deviceID: deviceID, mixer: mixer, onReading: onReading, onConfigurationChange: onConfigurationChange))
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else {
                if case .success(let box) = result { Self.discard(box) }
                return false
            }
            if self.micStart != nil, self.micGeneration == generation { self.micStart = nil }
            switch result {
            case .success(let box):
                // Superseded while starting (turned off, device changed
                // again, stream gone)
                guard self.micGeneration == generation else {
                    Self.discard(box)
                    return false
                }
                self.micEngine = box.engine
                self.micConfigurationObserver = box.observer
                self.mixer.attachMicrophone(box.feed)
                return true
            case .failure:
                guard self.micGeneration == generation else { return false }
                if reportFailure { self.microphoneFailed() }
                return false
            }
        }
        micStart = task
        return task
    }

    private nonisolated static func makeRunningMicEngine(
        deviceID: AudioDeviceID?,
        mixer: SystemAudioMixer,
        onReading: @escaping @Sendable (SystemAudioMixer.MicrophoneReading) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws -> MicEngineBox {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID {
            try bind(input, to: deviceID)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneError.noInputDevice
        }
        // Without a converter nothing would reach the mix while the meter
        // still moved; fail here, where the user can be told.
        guard let feed = mixer.makeMicrophoneFeed(inputFormat: format) else {
            throw MicrophoneError.unsupportedFormat
        }
        try installTap(on: input, format: format) { buffer in
            onReading(feed.process(buffer))
        }

        // Observed from before the engine starts, so a hardware change in the
        // moment between starting here and being taken over on the main
        // actor is not missed.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            onConfigurationChange()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            throw error
        }
        return MicEngineBox(engine: engine, feed: feed, observer: observer)
    }

    private func tearDownMicEngine() {
        releaseMicEngine()
        micLevel = 0
    }

    /// The teardown without the published state, so `deinit` can use it too.
    private func releaseMicEngine() {
        // Invalidates a start that is still in flight
        micGeneration += 1
        micStart = nil
        if let micConfigurationObserver {
            NotificationCenter.default.removeObserver(micConfigurationObserver)
        }
        micConfigurationObserver = nil
        // From here the old engine's tap writes nothing, whenever it stops
        mixer.detachMicrophone()
        if let micEngine {
            Self.stopInBackground(micEngine)
        }
        micEngine = nil
    }

    /// An engine that started but is not going to be used.
    private nonisolated static func discard(_ box: MicEngineBox) {
        NotificationCenter.default.removeObserver(box.observer)
        stopInBackground(box.engine)
    }

    private nonisolated static func stopInBackground(_ engine: AVAudioEngine) {
        let box = EngineReference(engine: engine)
        Task.detached(priority: .userInitiated) {
            box.engine.inputNode.removeTap(onBus: 0)
            box.engine.stop()
        }
    }

    /// Rebuilds the engine (new device or new hardware format). A recording
    /// in progress carries on: the microphone rejoins the mix as soon as the
    /// new engine delivers.
    private func restartMicKeepingRecording() {
        guard micEngine != nil || micStart != nil else { return }
        tearDownMicEngine()
        launchMicEngine(reportFailure: true)
    }

    /// The microphone can't be used. Says so and turns the option off, so
    /// neither the screen nor a recording claims a microphone that isn't
    /// there. A recording in progress continues with system audio only:
    /// stopping it would also lose the other side of the conversation.
    private func microphoneFailed() {
        tearDownMicEngine()
        includesMicrophone = false
        // Back to the system default, so that turning the option on again
        // doesn't run into the same device.
        selectedMicDeviceID = nil
        errorMessage = localized(isCapturing ? "system_audio_mic_lost" : "mic_monitor_failed")
    }

    /// Publishes what the tap thread measured for one buffer.
    private func apply(_ reading: SystemAudioMixer.MicrophoneReading, generation: Int) {
        guard generation == micGeneration, micEngine != nil else { return }
        micLevel = reading.level
        if reading.conversionFailed {
            microphoneFailed()
        }
    }

    private nonisolated static func bind(_ input: AVAudioInputNode, to deviceID: AudioDeviceID) throws {
        var device = deviceID
        func apply(_ unit: AudioUnit?) -> OSStatus {
            guard let unit else { return kAudioUnitErr_Uninitialized }
            return AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        let status: OSStatus
        if #available(macOS 27.0, *) {
            status = input.withAudioUnit { apply($0) }
        } else {
            status = apply(input.audioUnit)
        }
        guard status == noErr else { throw MicrophoneError.deviceUnavailable(status) }
    }

    /// Installs the input tap. macOS 27 has a throwing API; the older call
    /// raises an Objective-C exception on failure, which Swift cannot catch.
    private nonisolated static func installTap(
        on node: AVAudioNode,
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        // 100 ms: the smallest buffer the system supports, for a responsive
        // meter and a short delay before the microphone reaches the mix.
        let bufferSize = AVAudioFrameCount(format.sampleRate / 10)
        if #available(macOS 27.0, *) {
            try node.installAudioTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                handler(AVAudioPCMBuffer(copying: buffer))
            }
        } else {
            node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                handler(buffer)
            }
        }
    }

    private enum MicrophoneError: Error {
        case noInputDevice
        case deviceUnavailable(OSStatus)
        case unsupportedFormat
    }

    // MARK: - Sleep / wake

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        }
    }

    /// The system is about to stop the stream out from under us, and the mic
    /// engine can't run through sleep either. Stop both, but keep the file
    /// open so the recording resumes into it after wake.
    private func handleWillSleep() {
        guard isMonitoring || streamStart != nil else { return }
        resumeAfterWake = true
        isPausedForSleep = isCapturing
        tearDownMicEngine()
        tearDownStream()
    }

    private func handleDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        Task {
            // Also brings the microphone back, which reports its own failure
            let resumed = await startMonitoring()
            // Asleep again already: the next wake takes it from here
            guard !resumeAfterWake else { return }
            isPausedForSleep = false
            if !resumed, isCapturing {
                // The recording can't continue: finalise it so the audio
                // from before sleep isn't lost.
                stopCapture()
                errorMessage = localized("recording_resume_failed")
            }
        }
    }

    // MARK: - Devices

    private func observeHardware() {
        let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshInputDevices() }
        }
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshInputDevices() }
        }
        deviceListListener = listBlock
        defaultDeviceListener = defaultBlock
        var devices = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, listBlock)
        var defaultInput = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, defaultBlock)
    }

    private func removeHardwareObservers() {
        if let deviceListListener {
            var devices = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, deviceListListener)
        }
        if let defaultDeviceListener {
            var defaultInput = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, defaultDeviceListener)
        }
        deviceListListener = nil
        defaultDeviceListener = nil
    }

    private func refreshInputDevices() {
        let devices = Self.enumerateInputDevices()
        inputDevices = devices
        // Read only, to name the default in the device menu
        let defaultID = Self.defaultInputDevice()
        defaultDeviceName = devices.first(where: { $0.id == defaultID })?.name ?? ""
        // The picked device was unplugged: go back to following the default
        if let selected = selectedMicDeviceID, !devices.contains(where: { $0.id == selected }) {
            selectedMicDeviceID = nil
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func enumerateInputDevices() -> [AudioInputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            // Only devices with input streams
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }

            var nameAddress = Self.address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let value = name?.takeRetainedValue() else { return nil }
            return AudioInputDevice(id: id, name: value as String)
        }
    }

    // MARK: - Temp Directory

    private static func recordingsDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe")
            .appendingPathComponent("SystemAudio")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private enum StreamError: LocalizedError {
        case noDisplayFound

        var errorDescription: String? {
            switch self {
            case .noDisplayFound: return localized("system_audio_no_display")
            }
        }
    }
}

/// Carries a freshly started microphone engine back to the main actor.
private struct MicEngineBox: @unchecked Sendable {
    let engine: AVAudioEngine
    let feed: MicrophoneFeed
    let observer: NSObjectProtocol
}

/// Carries an engine to the background task that stops it.
private struct EngineReference: @unchecked Sendable {
    let engine: AVAudioEngine
}

// MARK: - SCStream Output Delegate

/// Receives one stream's audio and its end. A stream is identified by its
/// output object, so the service can tell the stream in use from one it has
/// already replaced.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let mixer: SystemAudioMixer
    /// Only read on the main queue.
    private weak var service: SystemAudioCaptureService?

    init(mixer: SystemAudioMixer, service: SystemAudioCaptureService) {
        self.mixer = mixer
        self.service = service
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let reading = mixer.process(sampleBuffer)
        DispatchQueue.main.async {
            self.service?.apply(reading, from: self)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.service?.streamDidStop(self)
        }
    }
}

// MARK: - Audio-thread state

/// Everything the stream's sample queue touches. The main actor only reaches
/// it through these methods.
///
/// System audio arrives on the sample queue, is copied into a PCM buffer,
/// has the microphone added from the ring buffer, and is written to the file
/// and handed to live transcription. The microphone's side is a
/// `MicrophoneFeed`, which only converts and fills the ring buffer.
private final class SystemAudioMixer: @unchecked Sendable {
    struct Reading: Sendable {
        /// System audio alone, before the microphone is added.
        var level: Float = 0
        /// Total frames in the recording file, when recording.
        var framesWritten: AVAudioFramePosition?
        /// A write has failed since the recording began.
        var writeFailed = false
    }

    struct MicrophoneReading: Sendable {
        /// The microphone as it goes into the mix.
        var level: Float = 0
        var conversionFailed = false
    }

    static let sampleRate = 48_000.0
    static let channelCount = 2

    /// What is metered, mixed and written: 48 kHz stereo float, one buffer
    /// per channel. It is also what the stream is asked to deliver.
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channelCount), interleaved: false)!
    private static let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private static let liveFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Live transcription is handed 100 ms at a time, like the blocks a
    /// microphone tap delivers: it counts its backlog while the model loads
    /// in blocks, and the stream's own buffers are several times smaller.
    private static let liveBlockSamples = 1_600

    // The microphone arrives in deliveries of 100 ms (the smallest an
    // AVAudioEngine tap supports) while the stream asks for a few
    // milliseconds at a time, so the reader has to stay a little behind the
    // writer. Both limits are measured when a delivery arrives, on what is
    // still unread at that moment (see `AudioRingBuffer`).
    //
    // 100 ms cushion: mixing starts once a delivery finds 100 ms unread,
    // which is the second delivery after a reset. From then on a delivery
    // can be up to 100 ms late without leaving a hole in the microphone
    // signal. Less, and ordinary scheduling jitter punches holes; more only
    // delays the microphone against the system audio.
    //
    // 300 ms limit: a microphone whose clock runs faster than the stream's
    // adds to the backlog bit by bit. When a delivery finds more than 300 ms
    // unread, the oldest audio is dropped, back to the cushion: one 200 ms
    // skip about once an hour at a typical 50 ppm mismatch, instead of the
    // microphone ending up 2 s (the capacity) behind the system audio.
    private static let micCushionFrames = Int(sampleRate * 0.1)
    private static let micMaxBacklogFrames = Int(sampleRate * 0.3)
    private static let micCapacityFrames = Int(sampleRate * 2)

    private let lock = NSLock()

    private let micRing = AudioRingBuffer(
        capacity: SystemAudioMixer.micCapacityFrames,
        channelCount: SystemAudioMixer.channelCount,
        cushionFrames: SystemAudioMixer.micCushionFrames,
        maxBacklogFrames: SystemAudioMixer.micMaxBacklogFrames
    )
    /// The feed of the engine in use, if the microphone is being mixed in.
    private var microphoneFeed: MicrophoneFeed?
    private var micScratch: [Float] = []

    // The buffers are kept between callbacks, so a steady stream allocates
    // nothing per buffer.
    private var streamDescription = AudioStreamBasicDescription()
    private var streamFormat: AVAudioFormat?
    /// Only when the stream delivers something other than `format`.
    private var streamConverter: AVAudioConverter?
    private var streamBuffer: AVAudioPCMBuffer?
    private var convertedBuffer: AVAudioPCMBuffer?

    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var writeFailed = false

    private var liveSink: (@Sendable ([Float]) -> Void)?
    private let liveConverter = AVAudioConverter(from: SystemAudioMixer.monoFormat, to: SystemAudioMixer.liveFormat)
    private var monoBuffer: AVAudioPCMBuffer?
    private var liveBuffer: AVAudioPCMBuffer?
    /// 16 kHz samples waiting to make up a full block.
    private var livePending: [Float] = []

    // MARK: Recording

    /// AAC rather than PCM: 48 kHz stereo float WAV is about 1.4 GB per hour
    /// and hits the 4 GB RIFF limit after about three hours.
    static func makeRecordingFile(at url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 160_000,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func beginRecording(file: AVAudioFile) {
        lock.lock()
        defer { lock.unlock() }
        self.file = file
        framesWritten = 0
        writeFailed = false
        livePending.removeAll(keepingCapacity: true)
        // Drop what the microphone buffered while only the meters ran, so it
        // lines up with the system audio from here on. Mixing starts when
        // the cushion has formed again.
        micRing.reset()
    }

    /// Closes the file and returns how many frames it holds.
    func endRecording() -> AVAudioFramePosition {
        lock.lock()
        file?.close()
        file = nil
        let frames = framesWritten
        // The last, partial block of live audio
        let sink = liveSink
        let rest = livePending
        livePending.removeAll(keepingCapacity: true)
        lock.unlock()

        if let sink, !rest.isEmpty {
            sink(rest)
        }
        return frames
    }

    func setLiveSink(_ sink: (@Sendable ([Float]) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        liveSink = sink
        liveConverter?.reset()
        livePending.removeAll(keepingCapacity: true)
    }

    // MARK: System audio

    /// Runs on the stream's sample queue for every audio buffer.
    func process(_ sampleBuffer: CMSampleBuffer) -> Reading {
        var reading = Reading()
        var liveBlock: [Float]?

        lock.lock()
        let sink = liveSink
        if let buffer = mixingBuffer(from: sampleBuffer) {
            reading.level = Self.level(of: buffer)
            if let file, !writeFailed {
                if microphoneFeed != nil {
                    addMicrophone(to: buffer)
                }
                do {
                    try file.write(from: buffer)
                    framesWritten += AVAudioFramePosition(buffer.frameLength)
                    if sink != nil {
                        liveBlock = nextLiveBlock(adding: buffer)
                    }
                } catch {
                    // Disk full or the file went away: stop instead of
                    // counting time that isn't being saved
                    writeFailed = true
                }
            }
        }
        if file != nil {
            reading.framesWritten = framesWritten
            // On every reading from here on, not only the one that failed:
            // a single report can be dropped on its way to the main actor.
            reading.writeFailed = writeFailed
        }
        lock.unlock()

        // Outside the lock: the sink is someone else's code
        if let sink, let liveBlock {
            sink(liveBlock)
        }
        return reading
    }

    /// Copies a sample buffer's audio into a PCM buffer in the mixing format.
    private func mixingBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var incoming = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return nil
        }

        // The stream says what it delivers; nothing below assumes a layout.
        if !Self.isSameFormat(incoming, streamDescription) {
            streamDescription = incoming
            streamBuffer = nil
            convertedBuffer = nil
            if Self.isMixingFormat(incoming) {
                streamFormat = Self.format
                streamConverter = nil
            } else {
                streamFormat = AVAudioFormat(streamDescription: &incoming)
                streamConverter = streamFormat.flatMap { Self.makeConverter(from: $0) }
                if streamConverter == nil { streamFormat = nil }
            }
        }
        guard let streamFormat,
              let buffer = Self.reusable(&streamBuffer, format: streamFormat, capacity: AVAudioFrameCount(frames)) else {
            return nil
        }

        // Setting the length sizes the buffer list this many frames per
        // channel buffer, which is what the copy below fills.
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr || Self.copyBytes(of: sampleBuffer, into: buffer) else { return nil }

        guard let streamConverter else { return buffer }
        let ratio = Self.sampleRate / streamFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let converted = Self.reusable(&convertedBuffer, format: Self.format, capacity: capacity),
              Self.convert(buffer, with: streamConverter, into: converted),
              converted.frameLength > 0 else {
            return nil
        }
        return converted
    }

    /// In case the Core Media copy refuses a buffer: the same bytes, taken
    /// straight from the block buffer. `CMBlockBufferCopyDataBytes` follows
    /// the block buffer across its segments (it need not be contiguous), and
    /// PCM is stored one channel after the other when non-interleaved — the
    /// order of the buffers in the list.
    private static func copyBytes(of sampleBuffer: CMSampleBuffer, into buffer: AVAudioPCMBuffer) -> Bool {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let needed = list.reduce(0) { $0 + Int($1.mDataByteSize) }
        guard CMBlockBufferGetDataLength(block) >= needed else { return false }
        var offset = 0
        for audioBuffer in list {
            let size = Int(audioBuffer.mDataByteSize)
            guard let destination = audioBuffer.mData,
                  CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: size, destination: destination) == kCMBlockBufferNoErr else {
                return false
            }
            offset += size
        }
        return true
    }

    /// Adds the microphone to `buffer`, as far as the ring buffer has it.
    /// Where it comes up short the system audio stays as it is.
    private func addMicrophone(to buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        if micScratch.count < frames * Self.channelCount {
            micScratch = [Float](repeating: 0, count: frames * Self.channelCount)
        }
        micScratch.withUnsafeMutableBufferPointer { scratch in
            guard let microphone = scratch.baseAddress else { return }
            let framesRead = micRing.read(into: microphone, frameCount: frames, channelCount: Self.channelCount)
            for channel in 0..<Self.channelCount {
                let destination = channels[channel]
                let source = microphone + channel * frames
                for frame in 0..<framesRead {
                    destination[frame] = max(-1, min(1, destination[frame] + source[frame]))
                }
            }
        }
    }

    /// Adds the buffer about to be written to the live feed, as 16 kHz mono,
    /// and returns a block once enough has gathered.
    private func nextLiveBlock(adding buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = buffer.frameLength
        guard let liveConverter,
              let channels = buffer.floatChannelData,
              let mono = Self.reusable(&monoBuffer, format: Self.monoFormat, capacity: frames),
              let monoSamples = mono.floatChannelData?[0] else {
            return nil
        }
        // Averaged by hand: asked to go from two channels to one, the
        // converter would keep the left channel and drop the right.
        mono.frameLength = frames
        for frame in 0..<Int(frames) {
            monoSamples[frame] = 0.5 * (channels[0][frame] + channels[1][frame])
        }

        // 48 kHz to 16 kHz is 3:1; the slack covers what the resampler
        // carries over from one buffer to the next.
        guard let live = Self.reusable(&liveBuffer, format: Self.liveFormat, capacity: frames / 3 + 64),
              Self.convert(mono, with: liveConverter, into: live),
              let samples = live.floatChannelData?[0] else {
            return nil
        }
        livePending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(live.frameLength)))
        guard livePending.count >= Self.liveBlockSamples else { return nil }
        let block = livePending
        livePending.removeAll(keepingCapacity: true)
        return block
    }

    // MARK: Microphone

    /// The tap-side half for one microphone engine, or `nil` if its format
    /// can't be converted. It writes nothing until it is attached.
    func makeMicrophoneFeed(inputFormat: AVAudioFormat) -> MicrophoneFeed? {
        Self.makeConverter(from: inputFormat).map { MicrophoneFeed(converter: $0, ring: micRing) }
    }

    /// Starts mixing in what `feed` delivers, in place of any earlier feed.
    func attachMicrophone(_ feed: MicrophoneFeed) {
        lock.lock()
        let previous = microphoneFeed
        microphoneFeed = feed
        lock.unlock()
        previous?.setActive(false)
        micRing.reset()
        feed.setActive(true)
    }

    func detachMicrophone() {
        lock.lock()
        let previous = microphoneFeed
        microphoneFeed = nil
        lock.unlock()
        previous?.setActive(false)
        micRing.reset()
    }

    // MARK: Helpers

    /// A converter into the mixing format. The channel map is spelled out
    /// because the default one maps an input with more than two channels and
    /// no standard layout (a multi-channel interface) to silence.
    static func makeConverter(from input: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: input, to: format) else { return nil }
        converter.channelMap = input.channelCount == 1 ? [0, 0] : [0, 1]
        return converter
    }

    /// Runs one buffer through a converter that is kept between calls, so the
    /// resampler's state carries over from buffer to buffer.
    static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, into output: AVAudioPCMBuffer) -> Bool {
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                // More input will come with the next buffer
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        return status != .error && error == nil
    }

    /// `buffer` if it is in `format` and holds `capacity` frames, otherwise a
    /// new one that replaces it.
    static func reusable(_ buffer: inout AVAudioPCMBuffer?, format: AVAudioFormat, capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let buffer, buffer.frameCapacity >= capacity, buffer.format == format {
            return buffer
        }
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        return buffer
    }

    private static func isSameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate
            && a.mFormatID == b.mFormatID
            && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    /// Whether the stream already delivers `format`, so its samples can be
    /// copied straight into a mixing buffer.
    private static func isMixingFormat(_ description: AudioStreamBasicDescription) -> Bool {
        let flags = description.mFormatFlags
        return description.mFormatID == kAudioFormatLinearPCM
            && description.mSampleRate == sampleRate
            && description.mChannelsPerFrame == UInt32(channelCount)
            && description.mBitsPerChannel == 32
            && flags & kAudioFormatFlagIsFloat != 0
            && flags & kAudioFormatFlagIsNonInterleaved != 0
            && flags & kAudioFormatFlagIsBigEndian == 0
    }

    /// RMS of the loudest channel, mapped from −60…0 dBFS to 0…1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var loudest: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            var sum: Float = 0
            for frame in 0..<frames {
                sum += samples[frame] * samples[frame]
            }
            loudest = max(loudest, (sum / Float(frames)).squareRoot())
        }
        let decibels = 20 * log10(max(loudest, 1e-6))
        return max(0, min(1, (decibels + 60) / 60))
    }
}

/// The microphone tap's side of the mix, one per engine: converts what the
/// tap delivers to the mixing format and writes it to the ring buffer.
///
/// An engine is started in the background and can be discarded again before
/// it is ever used, and an old one is stopped in the background after its
/// replacement is wanted. So a feed writes only while the mixer has it
/// attached; before and after, its tap's buffers go nowhere.
///
/// It has its own lock, so the tap never waits for a file write: the ring
/// buffer is the only thing the two audio threads share.
private final class MicrophoneFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let ring: AudioRingBuffer
    private var isActive = false
    private var converted: AVAudioPCMBuffer?
    private var planes: [Float] = []

    init(converter: AVAudioConverter, ring: AudioRingBuffer) {
        self.converter = converter
        self.ring = ring
    }

    /// Returns once a buffer being processed is done, so nothing from this
    /// feed reaches the ring buffer after it has been made inactive.
    func setActive(_ active: Bool) {
        lock.lock()
        isActive = active
        lock.unlock()
    }

    /// Runs on the tap thread for every captured microphone buffer.
    func process(_ buffer: AVAudioPCMBuffer) -> SystemAudioMixer.MicrophoneReading {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, buffer.frameLength > 0 else { return SystemAudioMixer.MicrophoneReading() }

        let ratio = SystemAudioMixer.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = SystemAudioMixer.reusable(&converted, format: SystemAudioMixer.format, capacity: capacity),
              SystemAudioMixer.convert(buffer, with: converter, into: converted),
              let channels = converted.floatChannelData else {
            return SystemAudioMixer.MicrophoneReading(conversionFailed: true)
        }

        let frames = Int(converted.frameLength)
        guard frames > 0 else { return SystemAudioMixer.MicrophoneReading() }

        // The ring buffer takes the channels back to back: [L…][R…]
        let channelCount = SystemAudioMixer.channelCount
        if planes.count < frames * channelCount {
            planes = [Float](repeating: 0, count: frames * channelCount)
        }
        planes.withUnsafeMutableBufferPointer { planes in
            guard let base = planes.baseAddress else { return }
            for channel in 0..<channelCount {
                (base + channel * frames).update(from: channels[channel], count: frames)
            }
            ring.write(from: base, frameCount: frames, channelCount: channelCount)
        }
        // Measured after conversion: the meter shows what is being mixed in
        return SystemAudioMixer.MicrophoneReading(level: SystemAudioMixer.level(of: converted))
    }
}
