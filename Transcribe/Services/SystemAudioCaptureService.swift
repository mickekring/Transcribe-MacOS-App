import Foundation
import TranscribeKit
import AVFoundation
import ScreenCaptureKit
import CoreAudio

/// Captures all system audio output using ScreenCaptureKit (macOS 13+),
/// optionally mixed with microphone input for recording both sides of a conversation.
///
/// Two-phase architecture:
/// 1. **Monitoring** (`startMonitoring`): Creates an SCStream for audio-only capture
///    with live level metering. Triggers the macOS permission prompt on first use.
/// 2. **Recording** (`startCapture`): Begins writing audio buffers to a WAV file.
///
/// When mic mixing is enabled, an AVAudioEngine captures mic input, resamples it
/// to 48kHz stereo, and feeds a ring buffer. The SCStream callback reads from the
/// ring buffer and mixes mic audio with system audio before writing to file.
class SystemAudioCaptureService: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - Published State
    
    @Published var isMonitoring = false
    @Published var isCapturing = false
    @Published var hasRecording = false
    @Published var recordingURL: URL?
    @Published var recordingDuration: TimeInterval = 0
    @Published var systemAudioLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var errorMessage: String?
    @Published var isPausedForSleep = false
    @Published var micSetupFailed = false

    // Mic device management
    @Published var micEnabled = false
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedMicDeviceID: AudioDeviceID?
    
    // MARK: - Private State (System Audio)
    
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    private var isStoppingStream = false

    /// Protects state shared between the main thread and the SCStream
    /// sample-handler queue: `audioFile`, `audioFormat`, `micMixingActive`,
    /// `micRingBuffer`.
    private let stateLock = NSLock()

    /// Bumped whenever monitoring is stopped so an in-flight async start
    /// (initial or post-wake) knows to tear down its freshly created stream.
    private var monitoringGeneration = 0

    /// Bumped on every mic stop/restart so a pending delayed restart can be cancelled.
    private var micRestartGeneration = 0
    
    // MARK: - Private State (Microphone)
    
    private var micEngine: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private var micRingBuffer: AudioRingBuffer?
    private var micMixingActive = false  // flag read on audio callback queue
    /// Receives the recorded (mixed) buffers for live transcription; guarded by `stateLock`
    private var liveBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var originalDefaultDevice: AudioDeviceID?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    // Target format for mic resampling (matches SCStream output)
    private let targetSampleRate: Double = 48000
    private let targetChannelCount: AVAudioChannelCount = 2

    // MARK: - Sleep/Wake State

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var wasCapturingBeforeSleep = false
    private var wasMicMonitoringBeforeSleep = false
    private var wasMicMixingBeforeSleep = false

    override init() {
        super.init()
        registerForSleepNotifications()
    }

    // MARK: - Phase 1: Monitoring (pre-recording level meter)

    func startMonitoring() async throws {
        guard !isMonitoring else { return }

        let generation = await MainActor.run { self.monitoringGeneration }

        let (newStream, output) = try await createStream()
        try await newStream.startCapture()

        // If monitoring was stopped while the stream was starting up (e.g. the
        // user left the view), tear the fresh stream down instead of leaking
        // a live capture nobody will stop.
        let installed = await MainActor.run { () -> Bool in
            guard self.monitoringGeneration == generation else { return false }
            self.stream = newStream
            self.streamOutput = output
            self.isMonitoring = true
            return true
        }
        if !installed {
            try? await newStream.stopCapture()
        }
    }

    /// Builds a fresh SCStream + output for system audio capture.
    /// Shared between initial `startMonitoring()` and the post-sleep restart.
    private func createStream() async throws -> (SCStream, AudioStreamOutput) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplayFound
        }

        let selfApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let excludedApps = selfApp.map { [$0] } ?? []
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let output = AudioStreamOutput(service: self)
        let newStream = SCStream(filter: filter, configuration: config, delegate: output)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.transcribe.systemAudioCapture", qos: .userInteractive))

        return (newStream, output)
    }

    // MARK: - Sleep/Wake Handling

    private func registerForSleepNotifications() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWillSleep()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemDidWake()
        }
    }

    private func removeSleepNotifications() {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        sleepObserver = nil
        wakeObserver = nil
    }

    /// Called just before the system sleeps. The OS is about to kill the SCStream
    /// out from under us regardless, so we tear it down ourselves first — but unlike
    /// `stopMonitoring()`/`stopCapture()`, we keep the audio file, recording URL, and
    /// `isCapturing` state intact so the recording resumes (instead of disappearing)
    /// once `handleSystemDidWake()` rebuilds the stream.
    private func handleSystemWillSleep() {
        guard isMonitoring else { return }

        wasCapturingBeforeSleep = isCapturing
        wasMicMonitoringBeforeSleep = micEngine != nil
        stateLock.lock()
        wasMicMixingBeforeSleep = micMixingActive
        stateLock.unlock()
        isPausedForSleep = true

        micEngine?.pause()

        let streamToStop = stream
        stream = nil
        streamOutput = nil
        isMonitoring = false
        systemAudioLevel = 0
        micLevel = 0

        if let streamToStop {
            Task.detached {
                try? await streamToStop.stopCapture()
            }
        }
    }

    private func handleSystemDidWake() {
        guard isPausedForSleep else { return }

        let generation = monitoringGeneration

        Task { @MainActor in
            do {
                let (newStream, output) = try await self.createStream()
                try await newStream.startCapture()

                // Monitoring was stopped while the stream was restarting —
                // don't install a live stream nobody will stop.
                guard self.monitoringGeneration == generation else {
                    try? await newStream.stopCapture()
                    return
                }

                self.stream = newStream
                self.streamOutput = output
                self.isMonitoring = true
                self.isPausedForSleep = false

                if self.wasMicMonitoringBeforeSleep {
                    if let engine = self.micEngine {
                        try? engine.start()
                    } else {
                        self.startMicMonitoring()
                    }
                }
                self.stateLock.withLock {
                    self.micMixingActive = self.wasMicMixingBeforeSleep
                }
            } catch {
                // Couldn't restart capture after wake — surface as a real error
                // since the recording can no longer continue. Finalize the
                // audio file so the already-captured audio isn't lost.
                self.isPausedForSleep = false
                self.stopCapture()
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func stopMonitoring() {
        guard !isStoppingStream else { return }
        isStoppingStream = true
        isPausedForSleep = false
        monitoringGeneration += 1

        let streamToStop = self.stream
        self.stream = nil
        self.streamOutput = nil
        stateLock.lock()
        self.audioFile = nil
        self.audioFormat = nil
        stateLock.unlock()

        // Stop mic monitoring too
        stopMicMonitoringInternal()

        if let streamToStop {
            Task.detached {
                try? await streamToStop.stopCapture()
            }
        }

        DispatchQueue.main.async {
            self.isMonitoring = false
            self.systemAudioLevel = 0
            self.micLevel = 0
            self.isStoppingStream = false
        }
    }
    
    // MARK: - Phase 2: Recording
    
    func startCapture(withMicrophone: Bool = false) throws {
        guard isMonitoring else {
            throw SystemAudioError.notMonitoring
        }

        if withMicrophone {
            stateLock.lock()
            let micReady = micRingBuffer != nil
            stateLock.unlock()
            guard micReady, micEngine != nil else {
                // Mic mixing was requested but the mic never started —
                // refuse to silently record a meeting without the user's voice.
                throw SystemAudioError.micCaptureFailed
            }
        }

        stateLock.lock()
        let currentFormat = audioFormat
        stateLock.unlock()

        let format = currentFormat ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        
        let outputURL = getTemporaryDirectory()
            .appendingPathComponent("system_recording_\(Date().timeIntervalSince1970).wav")
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved
        ]
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
        stateLock.lock()
        // Discard stale mic audio buffered during monitoring so the mic track
        // starts in sync with the system audio instead of lagging behind.
        micRingBuffer?.reset()
        self.audioFile = outputFile
        self.micMixingActive = withMicrophone
        stateLock.unlock()
        self.recordingURL = outputURL

        DispatchQueue.main.async {
            self.isCapturing = true
            self.hasRecording = false
            self.errorMessage = nil
        }
    }
    
    /// Live transcription receives exactly what is written to the file,
    /// mic mix included. Pass nil to disable.
    func setLiveBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        stateLock.lock()
        liveBufferHandler = handler
        stateLock.unlock()
    }

    // MARK: - Stop Capture
    
    func stopCapture() {
        // Taking the lock waits out any in-flight `write(from:)` on the
        // sample-handler queue, and releasing the file under the lock
        // finalizes the WAV before `hasRecording` is published below.
        stateLock.lock()
        micMixingActive = false
        if let file = audioFile {
            recordingDuration = Double(file.length) / file.fileFormat.sampleRate
        }
        audioFile = nil
        stateLock.unlock()

        DispatchQueue.main.async {
            self.isCapturing = false
            if self.recordingURL != nil {
                self.hasRecording = true
            }
        }
    }
    
    // MARK: - Delete Recording
    
    func deleteRecording() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        hasRecording = false
        recordingDuration = 0
    }
    
    // MARK: - Microphone Monitoring
    
    /// Starts capturing mic input for level metering and (optionally) mixing into recordings.
    func startMicMonitoring() {
        guard micEngine == nil else { return }

        micSetupFailed = false

        // Re-apply the user's selected device — a previous stop may have
        // restored the original system default behind the picker's back.
        if let deviceID = selectedMicDeviceID, getCurrentDefaultInputDevice() != deviceID {
            setInputDevice(deviceID)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)

        guard micFormat.sampleRate > 0 else {
            micSetupFailed = true
            return
        }

        // Create ring buffer: 2 seconds at 48kHz stereo
        let ringBuffer = AudioRingBuffer(capacity: Int(targetSampleRate) * 2, channelCount: Int(targetChannelCount))
        stateLock.lock()
        self.micRingBuffer = ringBuffer
        stateLock.unlock()

        // Create converter from mic's native format to 48kHz stereo float32 non-interleaved
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannelCount,
            interleaved: false
        )!
        
        let converter = AVAudioConverter(from: micFormat, to: targetFormat)
        self.micConverter = converter
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            guard let self else { return }
            
            // Calculate mic RMS from the raw input buffer
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrtf(sum / Float(frameLength))
                let level = max(0, min(1, (20 * log10f(max(rms, 1e-6)) + 60) / 60))
                DispatchQueue.main.async {
                    self.micLevel = level
                }
            }
            
            // Resample to target format and write to ring buffer
            guard let converter else { return }
            
            let ratio = self.targetSampleRate / micFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }
            
            var error: NSError?
            var hasData = true
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if hasData {
                    hasData = false
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            
            guard error == nil, outputBuffer.frameLength > 0 else { return }
            
            // Write resampled non-interleaved data to ring buffer
            // Layout: [L0..LN][R0..RN] — each channel contiguous
            let frameCount = Int(outputBuffer.frameLength)
            let chCount = Int(self.targetChannelCount)
            var interleavedForRing = [Float](repeating: 0, count: frameCount * chCount)
            
            for ch in 0..<chCount {
                if let src = outputBuffer.floatChannelData?[ch] {
                    let destOffset = ch * frameCount
                    for i in 0..<frameCount {
                        interleavedForRing[destOffset + i] = src[i]
                    }
                }
            }
            
            interleavedForRing.withUnsafeBufferPointer { ptr in
                ringBuffer.write(from: ptr.baseAddress!, frameCount: frameCount, channelCount: chCount)
            }
        }
        
        do {
            try engine.start()
            micEngine = engine
        } catch {
            // Mic engine failed to start
            stateLock.lock()
            micRingBuffer = nil
            stateLock.unlock()
            micConverter = nil
            micSetupFailed = true
        }
    }
    
    /// Stops mic monitoring and cleans up resources.
    func stopMicMonitoring() {
        stopMicMonitoringInternal()
        DispatchQueue.main.async {
            self.micLevel = 0
        }
    }
    
    private func stopMicMonitoringInternal() {
        micRestartGeneration += 1  // cancel any pending delayed restart
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        micEngine = nil
        micConverter = nil
        stateLock.lock()
        micRingBuffer?.reset()
        micRingBuffer = nil
        micMixingActive = false
        stateLock.unlock()
        micSetupFailed = false
        restoreOriginalDevice()
        removeDeviceObserver()
    }
    
    /// Restarts mic monitoring after a device change.
    /// Does NOT restore the original device — the caller has already set the new device.
    func restartMicMonitoring() {
        // Stop engine and tap without restoring the original device
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        micEngine = nil
        micConverter = nil
        stateLock.lock()
        micRingBuffer?.reset()
        micRingBuffer = nil
        stateLock.unlock()

        DispatchQueue.main.async {
            self.micLevel = 0
        }

        // Small delay to allow the system default device to update.
        // The generation check cancels the restart if the mic was stopped
        // in the meantime, so a stop isn't followed by a hot mic.
        micRestartGeneration += 1
        let generation = micRestartGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.micRestartGeneration == generation else { return }
            self.startMicMonitoring()
        }
    }
    
    // MARK: - Audio Device Management
    
    func refreshInputDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else { return }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return }
        
        var devices: [AudioInputDevice] = []
        
        for deviceID in deviceIDs {
            var inputStreamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(
                deviceID, &inputStreamAddress, 0, nil, &streamSize
            )
            guard streamStatus == noErr, streamSize > 0 else { continue }
            
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = AudioObjectGetPropertyData(
                deviceID, &nameAddress, 0, nil, &nameSize, &cfName
            )
            
            if nameStatus == noErr, let cfStr = cfName?.takeRetainedValue() {
                let name = cfStr as String
                devices.append(AudioInputDevice(id: deviceID, name: name))
            }
        }
        
        DispatchQueue.main.async {
            self.inputDevices = devices
            if self.selectedMicDeviceID == nil {
                self.selectedMicDeviceID = self.getCurrentDefaultInputDevice()
            }
        }
    }
    
    func getCurrentDefaultInputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID
        )
        return status == noErr ? deviceID : nil
    }
    
    func setInputDevice(_ deviceID: AudioDeviceID) {
        if originalDefaultDevice == nil {
            originalDefaultDevice = getCurrentDefaultInputDevice()
        }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var mutableDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, dataSize, &mutableDeviceID
        )
    }
    
    private func restoreOriginalDevice() {
        guard let originalDevice = originalDefaultDevice else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var mutableDeviceID = originalDevice
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, dataSize, &mutableDeviceID
        )
        originalDefaultDevice = nil
    }
    
    func observeDeviceChanges() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshInputDevices()
        }
        deviceListenerBlock = block
        
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, DispatchQueue.main, block
        )
    }
    
    private func removeDeviceObserver() {
        guard let block = deviceListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, DispatchQueue.main, block
        )
        deviceListenerBlock = nil
    }
    
    // MARK: - Audio Buffer Processing (called from SCStream output)
    
    func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }
        
        let asbd = asbdPointer.pointee

        // Hold the lock for the whole processing pass so the main thread
        // (start/stop capture, mic toggles) can't mutate `audioFormat`,
        // `audioFile`, `micMixingActive` or `micRingBuffer` mid-buffer —
        // in particular, stopCapture() can't close the file during a write.
        stateLock.lock()
        defer { stateLock.unlock() }

        if audioFormat == nil {
            var mutableASBD = asbd
            audioFormat = AVAudioFormat(streamDescription: &mutableASBD)
        }
        
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let format = audioFormat else { return }
        let channelCount = Int(format.channelCount)
        
        // Get raw audio data from CMSampleBuffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let dataStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard dataStatus == kCMBlockBufferNoErr, let dataPointer else { return }
        
        // Calculate system audio RMS
        let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
        let sampleCount = totalLength / MemoryLayout<Float>.size
        
        var sysSum: Float = 0
        for i in 0..<sampleCount {
            sysSum += floatPointer[i] * floatPointer[i]
        }
        let sysRms = sampleCount > 0 ? sqrtf(sysSum / Float(sampleCount)) : 0
        let sysLevel = max(0, min(1, (20 * log10f(max(sysRms, 1e-6)) + 60) / 60))
        
        DispatchQueue.main.async {
            self.systemAudioLevel = sysLevel
        }
        
        // Write to file if recording
        guard let audioFile = self.audioFile else { return }
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Copy system audio data into the PCM buffer
        if format.isInterleaved {
            if let dest = pcmBuffer.floatChannelData?[0] {
                memcpy(dest, dataPointer, min(totalLength, Int(pcmBuffer.frameLength) * channelCount * MemoryLayout<Float>.size))
            }
        } else {
            let framesBytes = Int(pcmBuffer.frameLength) * MemoryLayout<Float>.size
            for ch in 0..<channelCount {
                if let dest = pcmBuffer.floatChannelData?[ch] {
                    let offset = ch * framesBytes
                    if offset + framesBytes <= totalLength {
                        memcpy(dest, dataPointer.advanced(by: offset), framesBytes)
                    }
                }
            }
        }
        
        // Mix in microphone audio if enabled
        if micMixingActive, let ringBuffer = micRingBuffer {
            let framesToRead = frameCount
            var micData = [Float](repeating: 0, count: framesToRead * channelCount)
            
            let framesRead = micData.withUnsafeMutableBufferPointer { ptr -> Int in
                ringBuffer.read(into: ptr.baseAddress!, frameCount: framesToRead, channelCount: channelCount)
            }
            
            // Mix mic into the PCM buffer (add + clamp)
            // Non-interleaved layout: each channel is separate in floatChannelData
            if !format.isInterleaved {
                for ch in 0..<channelCount {
                    if let dest = pcmBuffer.floatChannelData?[ch] {
                        let micOffset = ch * framesToRead
                        for i in 0..<framesRead {
                            dest[i] = max(-1.0, min(1.0, dest[i] + micData[micOffset + i]))
                        }
                        // Frames beyond framesRead remain as system-audio-only (no mic data to mix)
                    }
                }
            } else {
                if let dest = pcmBuffer.floatChannelData?[0] {
                    // Interleaved dest is [L R L R ...], but micData from the
                    // ring buffer is non-interleaved: [L0..LN][R0..RN].
                    for frame in 0..<framesRead {
                        for ch in 0..<channelCount {
                            let destIndex = frame * channelCount + ch
                            let micIndex = ch * framesToRead + frame
                            dest[destIndex] = max(-1.0, min(1.0, dest[destIndex] + micData[micIndex]))
                        }
                    }
                }
            }
        }
        
        try? audioFile.write(from: pcmBuffer)
        liveBufferHandler?(pcmBuffer)
    }
    
    // MARK: - Temp Directory
    
    private func getTemporaryDirectory() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe")
            .appendingPathComponent("SystemAudio")
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return tempDir
    }
    
    deinit {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        restoreOriginalDevice()
        removeDeviceObserver()
        removeSleepNotifications()
        if let streamToStop = stream {
            Task.detached {
                try? await streamToStop.stopCapture()
            }
        }
        stream = nil
        streamOutput = nil
        audioFile = nil
    }
}

// MARK: - SCStream Output Delegate

private class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var service: SystemAudioCaptureService?
    
    init(service: SystemAudioCaptureService) {
        self.service = service
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        service?.processAudioBuffer(sampleBuffer)
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard let service = self.service else { return }
            // If we're paused for sleep, we tore this stream down ourselves —
            // this callback is expected and `handleSystemDidWake()` will rebuild
            // the stream, so don't surface it as a failure or drop the recording.
            guard !service.isPausedForSleep else { return }
            // Finalize any in-progress recording first so the audio captured
            // up to the failure stays playable and transcribable.
            service.stopCapture()
            service.errorMessage = error.localizedDescription
            service.isMonitoring = false
            service.systemAudioLevel = 0
            service.micLevel = 0
        }
    }
}

// MARK: - Errors

enum SystemAudioError: LocalizedError {
    case noDisplayFound
    case notMonitoring
    case formatConversionFailed
    case micPermissionDenied
    case micCaptureFailed

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for audio capture."
        case .notMonitoring:
            return "Audio monitoring must be started before recording."
        case .formatConversionFailed:
            return "Failed to read audio format."
        case .micPermissionDenied:
            return "Microphone permission is required to include your voice in the recording."
        case .micCaptureFailed:
            return "The microphone could not be started, so recording was not started. Turn off the microphone option or try again."
        }
    }
}
