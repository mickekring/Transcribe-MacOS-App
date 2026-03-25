import SwiftUI
import AVFoundation

struct SystemAudioRecordingView: View {
    @StateObject private var captureService = SystemAudioCaptureService()
    @EnvironmentObject var appState: AppState
    @State private var recordingTime: TimeInterval = 0
    @State private var recordingStartDate: Date?
    @State private var timer: Timer?
    @State private var isPlaying = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var showLeaveConfirmation = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var micMixingEnabled = false
    @State private var showPermissionAlert = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    if captureService.isCapturing || captureService.hasRecording {
                        showLeaveConfirmation = true
                    } else {
                        appState.showSystemAudioView = false
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
                
                Text(localized("system_audio"))
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
                
                // Info text and mic toggle (before first recording)
                if !captureService.isCapturing && !captureService.hasRecording {
                    VStack(spacing: 16) {
                        Text(micMixingEnabled
                             ? localized("mic_and_system_audio_info")
                             : localized("system_audio_permission_info"))
                            .font(.system(size: 13))
                            .foregroundColor(.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                        
                        // Include Microphone toggle
                        Toggle(isOn: $micMixingEnabled) {
                            Label(localized("include_microphone"), systemImage: "mic.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.textPrimary)
                        }
                        .toggleStyle(.switch)
                        .tint(.primaryAccent)
                        .frame(maxWidth: 280)
                        .onChange(of: micMixingEnabled) { _, enabled in
                            if enabled {
                                enableMicMixing()
                            } else {
                                captureService.stopMicMonitoring()
                            }
                        }
                        
                        // Mic device picker (shown when mic is enabled and multiple devices exist)
                        if micMixingEnabled && captureService.inputDevices.count > 1 {
                            Picker(localized("audio_input_device"), selection: $captureService.selectedMicDeviceID) {
                                ForEach(captureService.inputDevices) { device in
                                    Text(device.name).tag(Optional(device.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 300)
                            .onChange(of: captureService.selectedMicDeviceID) { _, newValue in
                                if let deviceID = newValue {
                                    captureService.setInputDevice(deviceID)
                                    captureService.restartMicMonitoring()
                                }
                            }
                        }
                    }
                }
                
                // Recording visualization
                ZStack {
                    // Outer ring
                    Circle()
                        .stroke(Color.borderLight, lineWidth: 2)
                        .frame(width: 200, height: 200)
                    
                    // Pulsing animation when capturing
                    if captureService.isCapturing {
                        Circle()
                            .fill(Color.primaryAccent.opacity(0.1))
                            .frame(width: 200, height: 200)
                            .scaleEffect(captureService.isCapturing ? 1.1 : 1.0)
                            .animation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: captureService.isCapturing)
                    }
                    
                    // Center button
                    Button(action: {
                        if captureService.isCapturing {
                            stopCapture()
                        } else if !captureService.hasRecording {
                            startCapture()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(captureService.isCapturing ? Color.red : Color.primaryAccent)
                                .frame(width: 120, height: 120)
                            
                            Image(systemName: captureService.isCapturing ? "stop.fill" : "speaker.wave.3.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(captureService.isCapturing ? 0.95 : 1.0)
                    .animation(.easeInOut(duration: 0.1), value: captureService.isCapturing)
                }
                
                // Time display and level meters
                VStack(spacing: 8) {
                    if captureService.isCapturing || captureService.hasRecording {
                        Text(formatTime(captureService.isCapturing ? recordingTime : captureService.recordingDuration))
                            .font(.system(size: 32, weight: .medium, design: .monospaced))
                            .foregroundColor(.textPrimary)
                        
                        Text(captureService.isCapturing ? localized("system_audio_recording_in_progress") : localized("system_audio_recording_complete"))
                            .font(.system(size: 14))
                            .foregroundColor(.textSecondary)
                    } else {
                        Text(localized("tap_to_record_system"))
                            .font(.system(size: 16))
                            .foregroundColor(.textSecondary)
                    }
                    
                    // Level meters — shown whenever monitoring is active (before and during recording)
                    if captureService.isMonitoring && !captureService.hasRecording {
                        VStack(spacing: 6) {
                            // System audio level meter
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 10))
                                    .foregroundColor(.textTertiary)
                                    .frame(width: 16)
                                
                                HStack(spacing: 2) {
                                    ForEach(0..<20, id: \.self) { index in
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(Float(index) / 20.0 < captureService.systemAudioLevel ? Color.primaryAccent : Color.borderLight)
                                            .frame(width: 8, height: 12)
                                    }
                                }
                                .animation(.linear(duration: 0.05), value: captureService.systemAudioLevel)
                            }
                            .frame(width: 220)
                            
                            // Mic level meter (shown when mic mixing is enabled)
                            if micMixingEnabled {
                                HStack(spacing: 4) {
                                    Image(systemName: "mic")
                                        .font(.system(size: 10))
                                        .foregroundColor(.textTertiary)
                                        .frame(width: 16)
                                    
                                    HStack(spacing: 2) {
                                        ForEach(0..<20, id: \.self) { index in
                                            RoundedRectangle(cornerRadius: 1.5)
                                                .fill(Float(index) / 20.0 < captureService.micLevel ? Color.secondaryAccent : Color.borderLight)
                                                .frame(width: 8, height: 12)
                                        }
                                    }
                                    .animation(.linear(duration: 0.05), value: captureService.micLevel)
                                }
                                .frame(width: 220)
                            }
                        }
                    }
                }
                
                // Controls when recording is done
                if captureService.hasRecording && !captureService.isCapturing {
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
                            captureService.deleteRecording()
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
                        if let recordingURL = captureService.recordingURL {
                            appState.showSystemAudioView = false
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
            Task {
                do {
                    try await captureService.startMonitoring()
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            audioPlayer?.stop()
            captureService.stopMonitoring()
        }
        .alert(localized("system_audio_error"), isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .alert(localized("leave_recording"), isPresented: $showLeaveConfirmation) {
            Button(localized("stay"), role: .cancel) { }
            Button(localized("leave"), role: .destructive) {
                if captureService.isCapturing {
                    captureService.stopCapture()
                    timer?.invalidate()
                    timer = nil
                }
                captureService.deleteRecording()
                captureService.stopMonitoring()
                appState.showSystemAudioView = false
            }
        } message: {
            Text(captureService.isCapturing
                 ? localized("recording_in_progress_leave")
                 : localized("untranscribed_recording_leave"))
        }
        .alert(localized("mic_permission_required"), isPresented: $showPermissionAlert) {
            Button("OK") {
                micMixingEnabled = false
            }
        } message: {
            Text(localized("mic_permission_message"))
        }
    }
    
    // MARK: - Mic Permission
    
    private func enableMicMixing() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            captureService.refreshInputDevices()
            captureService.observeDeviceChanges()
            captureService.startMicMonitoring()
        case .denied:
            showPermissionAlert = true
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        captureService.refreshInputDevices()
                        captureService.observeDeviceChanges()
                        captureService.startMicMonitoring()
                    } else {
                        showPermissionAlert = true
                    }
                }
            }
        @unknown default:
            break
        }
    }
    
    // MARK: - Recording Controls
    
    private func startCapture() {
        do {
            try captureService.startCapture(withMicrophone: micMixingEnabled)
            recordingTime = 0
            recordingStartDate = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
                if let startDate = recordingStartDate {
                    recordingTime = Date().timeIntervalSince(startDate)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func stopCapture() {
        captureService.stopCapture()
        timer?.invalidate()
        timer = nil
    }
    
    private func togglePlayback() {
        if isPlaying {
            audioPlayer?.pause()
            timer?.invalidate()
            timer = nil
            isPlaying = false
        } else {
            guard let url = captureService.recordingURL else { return }
            if !FileManager.default.fileExists(atPath: url.path) { return }
            
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.prepareToPlay()
                
                if audioPlayer?.play() == true {
                    isPlaying = true
                    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
                        if audioPlayer?.isPlaying == false {
                            isPlaying = false
                            timer?.invalidate()
                            timer = nil
                        }
                    }
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
