import SwiftUI
import AVFoundation
import CoreAudio
import AppKit

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

struct RecordingView: View {
    @StateObject private var audioRecorder = AudioRecorderManager()
    @EnvironmentObject var appState: AppState
    @State private var showingTranscription = false
    @State private var recordingTime: TimeInterval = 0
    @State private var recordingStartDate: Date?
    @State private var timer: Timer?
    @State private var isPlaying = false
    @State private var playbackTime: TimeInterval = 0
    @State private var audioPlayer: AVAudioPlayer?
    @State private var showPermissionAlert = false
    @State private var showLeaveConfirmation = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    if audioRecorder.isRecording || audioRecorder.hasRecording {
                        showLeaveConfirmation = true
                    } else {
                        appState.showRecordingView = false
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14))
                        Text(localized("back"))
                            .font(.system(size: 14))
                    }
                    .foregroundColor(.primaryAccent)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text(localized("new_recording"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.textPrimary)
                
                Spacer()
                
                // Placeholder for balance
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text(localized("back"))
                }
                .opacity(0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.surfaceBackground)
            .overlay(
                Rectangle()
                    .fill(Color.borderLight)
                    .frame(height: 1),
                alignment: .bottom
            )
            
            // Main content
            VStack(spacing: 40) {
                Spacer()
                
                // Audio input device selector
                if audioRecorder.inputDevices.count > 1 && !audioRecorder.isRecording {
                    VStack(spacing: 12) {
                        Picker(localized("audio_input_device"), selection: $audioRecorder.selectedDeviceID) {
                            ForEach(audioRecorder.inputDevices) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 300)
                        .onChange(of: audioRecorder.selectedDeviceID) { _, newValue in
                            if let deviceID = newValue {
                                audioRecorder.setInputDevice(deviceID)
                                // Restart input monitor to pick up new device
                                audioRecorder.restartInputMonitor()
                            }
                        }
                        
                        // Audio level meter (pre-recording input monitor)
                        HStack(spacing: 2) {
                            ForEach(0..<20, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Float(index) / 20.0 < audioRecorder.audioLevel ? Color.primaryAccent : Color.borderLight)
                                    .frame(width: 8, height: 12)
                            }
                        }
                        .animation(.linear(duration: 0.05), value: audioRecorder.audioLevel)
                        .frame(width: 200)
                    }
                }
                
                // Recording visualization
                ZStack {
                    // Outer ring
                    Circle()
                        .stroke(Color.borderLight, lineWidth: 2)
                        .frame(width: 200, height: 200)
                    
                    // Pulsing animation when recording
                    if audioRecorder.isRecording {
                        Circle()
                            .fill(Color.primaryAccent.opacity(0.1))
                            .frame(width: 200, height: 200)
                            .scaleEffect(audioRecorder.isRecording ? 1.1 : 1.0)
                            .animation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: audioRecorder.isRecording)
                    }
                    
                    // Center button
                    Button(action: {
                        if audioRecorder.isRecording {
                            stopRecording()
                        } else if audioRecorder.hasRecording {
                            // Show options
                        } else {
                            startRecording()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(audioRecorder.isRecording ? Color.red : Color.primaryAccent)
                                .frame(width: 120, height: 120)
                            
                            Image(systemName: audioRecorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(audioRecorder.isRecording ? 0.95 : 1.0)
                    .animation(.easeInOut(duration: 0.1), value: audioRecorder.isRecording)
                }
                
                // Time display
                VStack(spacing: 8) {
                    if audioRecorder.isRecording || audioRecorder.hasRecording {
                        Text(formatTime(audioRecorder.isRecording ? recordingTime : audioRecorder.recordingDuration))
                            .font(.system(size: 32, weight: .medium, design: .monospaced))
                            .foregroundColor(.textPrimary)
                        
                        Text(audioRecorder.isRecording ? localized("recording_in_progress") : localized("recording_complete"))
                            .font(.system(size: 14))
                            .foregroundColor(.textSecondary)
                        
                        // Audio level meter (shown during recording)
                        if audioRecorder.isRecording {
                            HStack(spacing: 2) {
                                ForEach(0..<20, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(Float(index) / 20.0 < audioRecorder.audioLevel ? Color.primaryAccent : Color.borderLight)
                                        .frame(width: 8, height: 12)
                                }
                            }
                            .animation(.linear(duration: 0.05), value: audioRecorder.audioLevel)
                            .frame(width: 200)
                        }
                    } else {
                        Text(localized("tap_to_record"))
                            .font(.system(size: 16))
                            .foregroundColor(.textSecondary)
                    }
                }
                
                // Controls when recording is done
                if audioRecorder.hasRecording && !audioRecorder.isRecording {
                    HStack(spacing: 24) {
                        // Play/Pause button
                        Button(action: togglePlayback) {
                            HStack(spacing: 8) {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                Text(isPlaying ? localized("pause") : localized("play"))
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.textPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.cardBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.borderLight, lineWidth: 0.5)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        
                        // Start over button
                        Button(action: {
                            audioRecorder.deleteRecording()
                            recordingTime = 0
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.counterclockwise")
                                Text(localized("start_over"))
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.textPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.cardBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.borderLight, lineWidth: 0.5)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Transcribe button
                    Button(action: {
                        if let recordingURL = audioRecorder.recordingURL {
                            appState.showRecordingView = false
                            appState.currentTranscriptionURL = recordingURL
                            appState.showTranscriptionView = true
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                            Text(localized("transcribe"))
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color.primaryAccent, Color.secondaryAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surfaceBackground)
        }
        .onAppear {
            audioRecorder.startInputMonitor()
        }
        .onDisappear {
            timer?.invalidate()
            audioPlayer?.stop()
            audioRecorder.stopInputMonitor()
        }
        .alert(localized("mic_permission_required"), isPresented: $showPermissionAlert) {
            Button("OK") { }
        } message: {
            Text(localized("mic_permission_message"))
        }
        .alert(localized("leave_recording"), isPresented: $showLeaveConfirmation) {
            Button(localized("stay"), role: .cancel) { }
            Button(localized("leave"), role: .destructive) {
                audioRecorder.stopInputMonitor()
                if audioRecorder.isRecording {
                    audioRecorder.stopRecording()
                    timer?.invalidate()
                    timer = nil
                }
                audioRecorder.deleteRecording()
                appState.showRecordingView = false
            }
        } message: {
            Text(audioRecorder.isRecording
                 ? localized("recording_in_progress_leave")
                 : localized("untranscribed_recording_leave"))
        }
    }
    
    private func startRecording() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showPermissionAlert = true
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.beginRecording()
                    } else {
                        self.showPermissionAlert = true
                    }
                }
            }
        @unknown default:
            break
        }
    }
    
    private func beginRecording() {
        audioRecorder.startRecording()
        recordingTime = 0
        recordingStartDate = Date()
        // Use Date-based calculation to avoid timer drift
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            if let startDate = recordingStartDate {
                recordingTime = Date().timeIntervalSince(startDate)
            }
        }
    }
    
    private func stopRecording() {
        audioRecorder.stopRecording()
        timer?.invalidate()
        timer = nil
        // Restart input monitor so user can still see levels
        audioRecorder.startInputMonitor()
    }
    
    private func togglePlayback() {
        if isPlaying {
            audioPlayer?.pause()
            timer?.invalidate()
            timer = nil
            isPlaying = false
        } else {
            guard let url = audioRecorder.recordingURL else {
                return
            }
            
            // Check if file exists
            if !FileManager.default.fileExists(atPath: url.path) {
                return
            }
            
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.prepareToPlay()
                
                if audioPlayer?.play() == true {
                    isPlaying = true
                    
                    // Poll for playback completion instead of using fixed asyncAfter
                    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
                        if audioPlayer?.isPlaying == false {
                            isPlaying = false
                            timer?.invalidate()
                            timer = nil
                        }
                    }
                } else {
                    // Playback failed to start
                }
            } catch {
                // Audio player creation failed
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let tenths = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

// Audio Recorder Manager
class AudioRecorderManager: NSObject, ObservableObject, AVAudioRecorderDelegate, @unchecked Sendable {
    @Published var isRecording = false
    @Published var hasRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingURL: URL?
    @Published var audioLevel: Float = 0
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedDeviceID: AudioDeviceID?
    
    private var audioRecorder: AVAudioRecorder?
    private var meteringTimer: Timer?
    private var originalDefaultDevice: AudioDeviceID?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    
    override init() {
        super.init()
        checkMicrophonePermission()
        refreshInputDevices()
        observeDeviceChanges()
    }
    
    deinit {
        // Stop audio engine synchronously if still running
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        meteringTimer?.invalidate()
        restoreOriginalDevice()
        removeDeviceObserver()
    }
    
    private func checkMicrophonePermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            AVAudioApplication.requestRecordPermission { _ in
            }
        case .denied:
            break
        @unknown default:
            break
        }
    }
    
    // MARK: - Audio Input Device Management
    
    func refreshInputDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return }
        
        var devices: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputStreamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(
                deviceID,
                &inputStreamAddress,
                0, nil,
                &streamSize
            )
            
            guard streamStatus == noErr, streamSize > 0 else { continue }
            
            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = AudioObjectGetPropertyData(
                deviceID,
                &nameAddress,
                0, nil,
                &nameSize,
                &cfName
            )
            
            if nameStatus == noErr, let cfStr = cfName?.takeRetainedValue() {
                let name = cfStr as String
                devices.append(AudioInputDevice(id: deviceID, name: name))
            }
        }
        
        DispatchQueue.main.async {
            self.inputDevices = devices
            // Set selected device to current default if not set
            if self.selectedDeviceID == nil {
                self.selectedDeviceID = self.getCurrentDefaultInputDevice()
            }
        }
    }
    
    private func getCurrentDefaultInputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        
        return status == noErr ? deviceID : nil
    }
    
    func setInputDevice(_ deviceID: AudioDeviceID) {
        // Store original default so we can restore later
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
            &propertyAddress,
            0, nil,
            dataSize,
            &mutableDeviceID
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
            &propertyAddress,
            0, nil,
            dataSize,
            &mutableDeviceID
        )
        originalDefaultDevice = nil
    }
    
    private func observeDeviceChanges() {
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
            &propertyAddress,
            DispatchQueue.main,
            block
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
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        deviceListenerBlock = nil
    }
    
    // MARK: - Audio Metering
    
    private func startMetering() {
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            // Normalize: -60dB..0dB → 0..1
            let normalized = max(0, min(1, (power + 60) / 60))
            DispatchQueue.main.async {
                self.audioLevel = normalized
            }
        }
    }
    
    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        DispatchQueue.main.async {
            self.audioLevel = 0
        }
    }
    
    // MARK: - Input Level Monitor (pre-recording)
    
    private var audioEngine: AVAudioEngine?
    
    func startInputMonitor() {
        guard !isRecording else { return }
        stopInputMonitor()
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        guard format.sampleRate > 0 else { return }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            
            // Calculate RMS
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(frameLength))
            // Convert to dB-like scale: map 0..1 range
            let level = max(0, min(1, (20 * log10f(max(rms, 1e-6)) + 60) / 60))
            
            DispatchQueue.main.async {
                self?.audioLevel = level
            }
        }
        
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            // Audio input monitor failed to start
        }
    }
    
    func stopInputMonitor() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        audioLevel = 0
    }
    
    func restartInputMonitor() {
        stopInputMonitor()
        // Small delay to allow the system default device to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startInputMonitor()
        }
    }
    
    func startRecording() {
        let audioFilename = getTemporaryDirectory().appendingPathComponent("recording_\(Date().timeIntervalSince1970).m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            
            stopInputMonitor()
            
            if audioRecorder?.record() == true {
                recordingURL = audioFilename
                isRecording = true
                hasRecording = false
                startMetering()
            }
        } catch {
            // Audio recorder creation failed
        }
    }
    
    func stopRecording() {
        guard let recorder = audioRecorder else {
            return
        }
        
        stopMetering()
        recordingDuration = recorder.currentTime
        recorder.stop()
        isRecording = false
        restoreOriginalDevice()
        
        // Verify the file was created
        if let url = recordingURL, FileManager.default.fileExists(atPath: url.path) {
            hasRecording = true
        } else {
            hasRecording = false
        }
    }
    
    func deleteRecording() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        hasRecording = false
        recordingDuration = 0
    }
    
    private func getTemporaryDirectory() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe")
            .appendingPathComponent("Recordings")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: tempDir, 
                                                withIntermediateDirectories: true, 
                                                attributes: nil)
        return tempDir
    }
    
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            hasRecording = false
        }
    }
}