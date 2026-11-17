import AVFoundation
import AudioToolbox
import CoreAudio
import AppKit
import TranscribeKit

/// Microphone capture on a single `AVAudioEngine`.
///
/// One input tap drives everything: the level meter, the recording file and
/// the 16 kHz feed for live transcription. Because all three come from the
/// same buffers they can't drift apart, and the recorded duration is counted
/// in frames written rather than wall-clock time (so sleep, device changes
/// and restarts never inflate it).
///
/// The input device is bound on the engine's own audio unit. The system-wide
/// default input device is never changed, so other apps (a Teams or Zoom call
/// on "system default") are unaffected by what is picked here.
@MainActor
final class MicrophoneCapture: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var hasRecording = false
    @Published private(set) var isPausedForSleep = false
    /// Seconds of audio written to the current (or last) recording.
    @Published private(set) var recordedSeconds: TimeInterval = 0
    @Published private(set) var recordingURL: URL?
    /// 0…1, mapped from −60…0 dBFS.
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    /// Name of the device the system currently uses by default.
    @Published private(set) var defaultDeviceName: String = ""
    /// `nil` follows the system default input device.
    @Published var selectedDeviceID: AudioDeviceID? {
        didSet {
            guard selectedDeviceID != oldValue else { return }
            restartEngineKeepingRecording()
        }
    }
    @Published var errorMessage: String?

    /// Recording file format: 48 kHz mono. Speech needs no more, and a fixed
    /// format lets a recording continue across input-device changes.
    private static let fileSampleRate = 48_000.0
    private static let liveSampleRate = 16_000.0

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private let tapState = TapState()

    init() {
        refreshInputDevices()
        observeHardware()
        observeSleep()
    }

    deinit {
        // Listener blocks capture self weakly; removing them needs the block
        // objects, which are only reachable from here.
        MainActor.assumeIsolated {
            tearDownEngine()
            removeHardwareObservers()
            if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        }
    }

    // MARK: - Monitoring

    /// Starts the engine so the level meter moves. Safe to call repeatedly.
    func startMonitoring() {
        #if DEBUG
        guard !usesInjectedAudio else { return }
        #endif
        guard engine == nil, !isPausedForSleep else { return }
        do {
            try startEngine()
        } catch {
            errorMessage = String(format: localized("mic_start_failed"), error.localizedDescription)
        }
    }

    /// Stops the engine. A recording in progress is finalised first.
    func stopMonitoring() {
        if isRecording { stopRecording() }
        tearDownEngine()
        audioLevel = 0
    }

    // MARK: - Recording

    /// Starts writing the microphone to a new temporary file.
    /// - Returns: false (with `errorMessage` set) if recording could not start.
    @discardableResult
    func startRecording() -> Bool {
        guard !isRecording else { return true }
        errorMessage = nil
        var needsEngine = engine == nil
        #if DEBUG
        if usesInjectedAudio { needsEngine = false }
        #endif
        if needsEngine {
            do {
                try startEngine()
            } catch {
                errorMessage = String(format: localized("mic_start_failed"), error.localizedDescription)
                return false
            }
        }

        let url = Self.recordingsDirectory().appendingPathComponent("recording_\(UUID().uuidString).m4a")
        do {
            let file = try Self.makeRecordingFile(at: url)
            tapState.beginRecording(file: file)
        } catch {
            errorMessage = String(format: localized("mic_start_failed"), error.localizedDescription)
            return false
        }

        recordingURL = url
        recordedSeconds = 0
        hasRecording = false
        isRecording = true
        return true
    }

    /// Finalises the recording file. The engine keeps running for the meter.
    func stopRecording() {
        guard isRecording else { return }
        let frames = tapState.endRecording()
        isRecording = false
        isPausedForSleep = false
        recordedSeconds = Double(frames) / Self.fileSampleRate

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
        if isRecording {
            _ = tapState.endRecording()
            isRecording = false
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

    #if DEBUG
    /// When set, audio comes from `debugInject(_:)` instead of the input
    /// device, so the whole pipeline after the tap — meter, file, live feed —
    /// can be exercised without a microphone or a person speaking.
    var usesInjectedAudio = false

    /// Feeds a buffer exactly as the microphone tap would.
    func debugInject(_ buffer: AVAudioPCMBuffer) {
        tapState.configureIfNeeded(inputFormat: buffer.format, fileSampleRate: Self.fileSampleRate, liveSampleRate: Self.liveSampleRate)
        apply(tapState.process(buffer))
    }
    #endif

    // MARK: - Live feed

    /// Receives the microphone as 16 kHz mono samples while the engine runs.
    /// Called on the audio tap thread; pass `nil` to stop.
    func setLiveSink(_ sink: (@Sendable ([Float]) -> Void)?) {
        tapState.setLiveSink(sink)
    }

    // MARK: - Engine

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let deviceID = selectedDeviceID {
            // A selected device that has since been unplugged falls back to
            // the system default rather than failing the recording.
            if inputDevices.contains(where: { $0.id == deviceID }) {
                try Self.bind(input, to: deviceID)
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        tapState.configure(inputFormat: format, fileSampleRate: Self.fileSampleRate, liveSampleRate: Self.liveSampleRate)

        let state = tapState
        try Self.installTap(on: input, format: format) { [weak self] buffer in
            let reading = state.process(buffer)
            DispatchQueue.main.async {
                self?.apply(reading)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine

        // The engine stops itself when the input hardware changes (device
        // unplugged, AirPods connected, sample rate switched). Rebuild it so
        // the recording carries on instead of silently going quiet.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartEngineKeepingRecording()
            }
        }
    }

    /// Publishes what the tap thread measured for one buffer.
    private func apply(_ reading: TapState.Reading) {
        audioLevel = reading.level
        if let frames = reading.framesWritten {
            recordedSeconds = Double(frames) / Self.fileSampleRate
        }
        if reading.writeFailed {
            handleWriteFailure()
        }
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Rebuilds the engine (new device or new hardware format). An open
    /// recording file stays open and keeps receiving audio.
    private func restartEngineKeepingRecording() {
        guard engine != nil else { return }
        tearDownEngine()
        do {
            try startEngine()
        } catch {
            let wasRecording = isRecording
            if wasRecording { stopRecording() }
            audioLevel = 0
            errorMessage = wasRecording
                ? localized("mic_lost_during_recording")
                : String(format: localized("mic_start_failed"), error.localizedDescription)
        }
    }

    private func handleWriteFailure() {
        guard isRecording else { return }
        stopRecording()
        errorMessage = localized("recording_write_failed")
    }

    private static func bind(_ input: AVAudioInputNode, to deviceID: AudioDeviceID) throws {
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
        guard status == noErr else { throw CaptureError.deviceUnavailable(status) }
    }

    /// Installs the input tap. macOS 27 has a throwing API; the older call
    /// raises an Objective-C exception on failure, which Swift cannot catch.
    private static func installTap(
        on node: AVAudioNode,
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        // 100 ms: the smallest buffer the system supports, for a responsive
        // meter and low live-transcription latency.
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

    private static func makeRecordingFile(at url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: fileSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func recordingsDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe")
            .appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    enum CaptureError: LocalizedError {
        case noInputDevice
        case deviceUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return localized("mic_no_input_device")
            case .deviceUnavailable: return localized("mic_device_unavailable")
            }
        }
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

    /// The engine can't run through sleep. Stop it but keep the file open so
    /// the recording resumes into the same file after wake.
    private func handleWillSleep() {
        guard engine != nil else { return }
        isPausedForSleep = isRecording
        tearDownEngine()
        audioLevel = 0
    }

    private func handleDidWake() {
        let wasRecording = isPausedForSleep
        isPausedForSleep = false
        guard wasRecording || engine == nil else { return }
        do {
            try startEngine()
        } catch {
            if wasRecording {
                stopRecording()
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

    func refreshInputDevices() {
        let devices = Self.enumerateInputDevices()
        inputDevices = devices
        let defaultID = Self.defaultInputDevice()
        defaultDeviceName = devices.first(where: { $0.id == defaultID })?.name ?? ""
        // The picked device was unplugged: go back to following the default
        if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
            selectedDeviceID = nil
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
}

// MARK: - Tap-side state

/// Everything the audio tap thread touches, behind one lock. The main actor
/// only reaches it through these methods.
private final class TapState: @unchecked Sendable {
    struct Reading {
        var level: Float = 0
        /// Total frames in the recording file, when recording.
        var framesWritten: AVAudioFramePosition?
        var writeFailed = false
    }

    private let lock = NSLock()
    private var inputFormat: AVAudioFormat?
    private var fileFormat: AVAudioFormat?
    private var liveFormat: AVAudioFormat?
    private var fileConverter: AVAudioConverter?
    private var liveConverter: AVAudioConverter?
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var writeFailed = false
    private var liveSink: (@Sendable ([Float]) -> Void)?

    func configure(inputFormat: AVAudioFormat, fileSampleRate: Double, liveSampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.inputFormat = inputFormat
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileSampleRate, channels: 1, interleaved: false)
        let liveFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: liveSampleRate, channels: 1, interleaved: false)
        self.fileFormat = fileFormat
        self.liveFormat = liveFormat
        // New converters for the new input format; the file (if open) stays
        fileConverter = fileFormat.flatMap { AVAudioConverter(from: inputFormat, to: $0) }
        liveConverter = liveFormat.flatMap { AVAudioConverter(from: inputFormat, to: $0) }
    }

    #if DEBUG
    func configureIfNeeded(inputFormat: AVAudioFormat, fileSampleRate: Double, liveSampleRate: Double) {
        lock.lock()
        let matches = self.inputFormat == inputFormat
        lock.unlock()
        if !matches {
            configure(inputFormat: inputFormat, fileSampleRate: fileSampleRate, liveSampleRate: liveSampleRate)
        }
    }
    #endif

    func beginRecording(file: AVAudioFile) {
        lock.lock()
        defer { lock.unlock() }
        self.file = file
        framesWritten = 0
        writeFailed = false
        fileConverter?.reset()
    }

    /// Closes the file and returns how many frames it holds.
    func endRecording() -> AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
        return framesWritten
    }

    func setLiveSink(_ sink: (@Sendable ([Float]) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        liveSink = sink
        liveConverter?.reset()
    }

    /// Runs on the tap thread for every captured buffer.
    func process(_ buffer: AVAudioPCMBuffer) -> Reading {
        var reading = Reading(level: Self.level(of: buffer))

        lock.lock()
        let sink = liveSink
        var liveSamples: [Float]?
        if sink != nil, let liveConverter, let liveFormat,
           let converted = Self.convert(buffer, with: liveConverter, to: liveFormat),
           let channel = converted.floatChannelData?[0] {
            liveSamples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        }
        if let file, !writeFailed, let fileConverter, let fileFormat {
            if let converted = Self.convert(buffer, with: fileConverter, to: fileFormat), converted.frameLength > 0 {
                do {
                    try file.write(from: converted)
                    framesWritten += AVAudioFramePosition(converted.frameLength)
                } catch {
                    // Disk full or the file went away: stop instead of
                    // counting time that isn't being saved
                    writeFailed = true
                    reading.writeFailed = true
                }
            }
            reading.framesWritten = framesWritten
        }
        lock.unlock()

        // Outside the lock: the sink is someone else's code
        if let sink, let liveSamples, !liveSamples.isEmpty {
            sink(liveSamples)
        }
        return reading
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                // More input will come with the next tap buffer; keeping the
                // converter mid-stream preserves its resampler state.
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return output
    }

    /// RMS of the loudest channel, mapped from −60…0 dBFS to 0…1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
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
