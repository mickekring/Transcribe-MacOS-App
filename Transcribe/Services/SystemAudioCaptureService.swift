import Foundation
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
    
    // MARK: - Private State (Microphone)
    
    private var micEngine: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private var micRingBuffer: AudioRingBuffer?
    private var micMixingActive = false  // flag read on audio callback queue
    private var originalDefaultDevice: AudioDeviceID?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    
    // Target format for mic resampling (matches SCStream output)
    private let targetSampleRate: Double = 48000
    private let targetChannelCount: AVAudioChannelCount = 2
    
    // MARK: - Phase 1: Monitoring (pre-recording level meter)
    
    func startMonitoring() async throws {
        guard !isMonitoring else { return }
        
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
        
        try await newStream.startCapture()
        
        self.stream = newStream
        self.streamOutput = output
        
        await MainActor.run {
            self.isMonitoring = true
        }
    }
    
    func stopMonitoring() {
        guard !isStoppingStream else { return }
        isStoppingStream = true
        
        let streamToStop = self.stream
        self.stream = nil
        self.streamOutput = nil
        self.audioFile = nil
        self.audioFormat = nil
        
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
        
        let format = audioFormat ?? AVAudioFormat(
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
        self.audioFile = outputFile
        self.recordingURL = outputURL
        self.micMixingActive = withMicrophone
        
        DispatchQueue.main.async {
            self.isCapturing = true
            self.hasRecording = false
            self.errorMessage = nil
        }
    }
    
    // MARK: - Stop Capture
    
    func stopCapture() {
        micMixingActive = false
        
        if let file = audioFile {
            recordingDuration = Double(file.length) / file.fileFormat.sampleRate
        }
        audioFile = nil
        
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
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        
        guard micFormat.sampleRate > 0 else { return }
        
        // Create ring buffer: 2 seconds at 48kHz stereo
        let ringBuffer = AudioRingBuffer(capacity: Int(targetSampleRate) * 2, channelCount: Int(targetChannelCount))
        self.micRingBuffer = ringBuffer
        
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
            micRingBuffer = nil
            micConverter = nil
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
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        micEngine = nil
        micConverter = nil
        micRingBuffer?.reset()
        micRingBuffer = nil
        micMixingActive = false
        restoreOriginalDevice()
        removeDeviceObserver()
    }
    
    /// Restarts mic monitoring after a device change.
    func restartMicMonitoring() {
        stopMicMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startMicMonitoring()
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
                    // Interleaved: samples are [L R L R ...]
                    for i in 0..<(framesRead * channelCount) {
                        dest[i] = max(-1.0, min(1.0, dest[i] + micData[i]))
                    }
                }
            }
        }
        
        try? audioFile.write(from: pcmBuffer)
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
            self.service?.errorMessage = error.localizedDescription
            self.service?.isMonitoring = false
            self.service?.isCapturing = false
            self.service?.systemAudioLevel = 0
            self.service?.micLevel = 0
        }
    }
}

// MARK: - Errors

enum SystemAudioError: LocalizedError {
    case noDisplayFound
    case notMonitoring
    case formatConversionFailed
    case micPermissionDenied
    
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
        }
    }
}
