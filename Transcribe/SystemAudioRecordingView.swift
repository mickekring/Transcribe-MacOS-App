import SwiftUI
import Combine
import TranscribeKit
import AVFoundation
import CoreAudio

/// System audio recording, optionally mixed with the microphone, with live
/// text when a Parakeet-family model is available.
struct SystemAudioRecordingView: View {
    @StateObject private var capture = SystemAudioCaptureService()
    @StateObject private var live = LiveTranscriptController()
    @EnvironmentObject var appState: AppState
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel: String = "kb_whisper-small-coreml"
    @AppStorage("liveTranscriptionEnabled") private var liveEnabled = true

    @State private var systemLevels = LevelHistory()
    @State private var micLevels = LevelHistory(capacity: Self.micMeterBars)
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    /// Bumped to (re)start monitoring: on appear and after "Start over".
    @State private var monitoringRequest = 0
    /// A recording is being started; the stream can take a moment to open.
    @State private var startTask: Task<Void, Never>?
    @State private var isStarting = false
    @State private var showMicPermissionAlert = false
    @State private var showScreenPermissionAlert = false
    /// The recording was passed to the transcription screen and must survive this view.
    @State private var handedOff = false

    private let meterTick = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    /// Meters and option rows share one width so their edges line up.
    private static let columnWidth: CGFloat = 330
    private static let micMeterBars = 36
    /// Told apart from the system meter, which is green or (recording) red.
    private static let micMeterColor = Color.blue

    /// The model that would produce live text right now, if any.
    private var liveModelId: String? {
        ParakeetService.liveModelId(selectedModel: selectedModel, languageCode: languageManager.selectedLanguage.code)
    }

    private var showsLivePanel: Bool {
        (liveEnabled && liveModelId != nil) || live.hasText || live.isActive
    }

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(maxWidth: showsLivePanel ? 440 : .infinity, maxHeight: .infinity)

            if showsLivePanel {
                LiveTranscriptPanel(live: live, isRecording: capture.isCapturing, idleHint: localized("live_idle_hint_system"))
                    .padding(.vertical, Metrics.gutter)
                    .padding(.trailing, Metrics.gutter)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: showsLivePanel)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BackToolbarButton {
                    appState.navigate(to: .home)
                }
            }
        }
        // Cancelled when the screen goes away, so a start that had not begun
        // yet cannot open a stream nobody is left to stop.
        .task(id: monitoringRequest) {
            // The meter only starts by itself once access has been granted.
            // Opening the stream is what makes macOS ask, and that should
            // happen when the user presses Record, not merely by opening this
            // screen (Record opens the stream itself if it isn't running).
            guard CGPreflightScreenCaptureAccess() else { return }
            await capture.startMonitoring()
        }
        .onDisappear {
            startTask?.cancel()
            stopPlayback()
            live.reset()
            capture.setLiveSink(nil)
            if !handedOff {
                // Leaving was confirmed (or there was nothing to lose)
                capture.deleteRecording()
            }
            capture.stopMonitoring()
        }
        .onReceive(meterTick) { _ in
            systemLevels.append(capture.systemAudioLevel)
            micLevels.append(capture.micLevel)
        }
        .onChange(of: capture.isCapturing) { _, _ in reportUnsavedWork() }
        .onChange(of: capture.hasRecording) { _, _ in reportUnsavedWork() }
        .onChange(of: capture.isCapturing) { wasCapturing, isCapturing in
            // Stopped with the button, or on its own (the stream ended, the
            // disk filled up, capture did not come back after sleep)
            if wasCapturing && !isCapturing {
                capture.setLiveSink(nil)
                Task { await live.finish() }
            }
        }
        .alert(localized("mic_permission_required"), isPresented: $showMicPermissionAlert) {
            Button(localized("open_system_settings")) {
                openPrivacySettings("Privacy_Microphone")
            }
            Button(localized("cancel"), role: .cancel) { }
        } message: {
            Text(localized("mic_permission_message"))
        }
        .alert(localized("system_audio_permission_required"), isPresented: $showScreenPermissionAlert) {
            Button(localized("open_system_settings")) {
                openPrivacySettings("Privacy_ScreenCapture")
            }
            Button(localized("cancel"), role: .cancel) { }
        } message: {
            Text(localized("system_audio_permission_message"))
        }
        // No actions: the system supplies its own OK button
        .alert(localized("system_audio_error"), isPresented: captureErrorBinding) {
        } message: {
            Text(capture.errorMessage ?? "")
        }
    }

    private var captureErrorBinding: Binding<Bool> {
        Binding(
            get: { capture.errorMessage != nil },
            set: { if !$0 { capture.errorMessage = nil } }
        )
    }

    // MARK: - Controls column

    private var controls: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            sectionGap

            VStack(spacing: 8) {
                Text(localized("system_audio"))
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                statusBadge
            }

            sectionGap
            recordButton
            sectionGap

            VStack(spacing: 14) {
                Text(formatClock(capture.recordedSeconds))
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(capture.isCapturing || capture.hasRecording ? Color.textPrimary : Color.textTertiary)
                    .contentTransition(.numericText())
                    .accessibilityLabel(localized("recording_duration"))
                    .accessibilityValue(formatClock(capture.recordedSeconds, tenths: false))

                meters
            }

            sectionGap

            if capture.hasRecording && !capture.isCapturing {
                finishedActions
            } else if capture.permissionDenied {
                permissionNotice
            } else {
                setupOptions
            }

            sectionGap
            Spacer(minLength: 8)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// The space between sections: 26 pt, as on the microphone screen. With
    /// the microphone rows showing, this column is taller than that one, so
    /// in a window at its smallest the gaps give way rather than the content
    /// running past the window's edges.
    private var sectionGap: some View {
        Spacer(minLength: 8)
            .frame(maxHeight: 26)
    }

    private var statusBadge: some View {
        Group {
            if capture.isPausedForSleep {
                StatusBadge(text: localized("system_audio_recording_paused"), color: .orange)
            } else if capture.isCapturing {
                StatusBadge(text: localized("system_audio_recording_in_progress"), color: .recordingRed, isPulsing: true)
            } else if capture.hasRecording {
                StatusBadge(text: localized("system_audio_recording_complete"), color: .primaryAccent)
            } else if capture.permissionDenied {
                StatusBadge(text: localized("system_audio_permission_required"), color: .orange)
            } else {
                StatusBadge(text: localized("tap_to_record_system"), color: .textTertiary)
            }
        }
        .frame(height: 18)
    }

    private var recordButton: some View {
        let isCapturing = capture.isCapturing
        let isUnavailable = capture.hasRecording && !isCapturing
        return ZStack {
            // A halo that follows the system audio level: direct feedback
            // that sound is arriving, before and during recording.
            Circle()
                .fill((isCapturing ? Color.recordingRed : Color.brandGreen).opacity(0.16))
                .frame(width: 150, height: 150)
                .scaleEffect(1 + CGFloat(capture.systemAudioLevel) * 0.32)
                .animation(.easeOut(duration: 0.12), value: capture.systemAudioLevel)
                .accessibilityHidden(true)

            Button(action: toggleCapture) {
                Image(systemName: isCapturing ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(isCapturing ? Color.white : Color.onAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 124, height: 124)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(isCapturing ? Color.recordingRed : Color.primaryAccent).interactive(),
                in: .circle
            )
            .disabled(isUnavailable)
            .opacity(isUnavailable ? 0.45 : 1)
            .keyboardShortcut(.space, modifiers: [])
            .help(isCapturing ? localized("stop_recording") : localized("start_recording"))
            .accessibilityLabel(isCapturing ? localized("stop_recording") : localized("start_recording"))
        }
        .frame(height: 190)
    }

    /// System audio, and below it — smaller, in its own colour — the
    /// microphone while it is being mixed in.
    private var meters: some View {
        let isActive = capture.isCapturing || !capture.hasRecording
        let showsMicrophone = capture.includesMicrophone && isActive
        return VStack(spacing: 10) {
            WaveformMeter(
                levels: systemLevels.levels,
                color: capture.isCapturing ? .recordingRed : .primaryAccent,
                isActive: isActive
            )
            .frame(width: Self.columnWidth, height: 52)

            if showsMicrophone {
                HStack(spacing: 10) {
                    Label(localized("microphone"), systemImage: "mic.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    WaveformMeter(
                        levels: micLevels.levels,
                        barCount: Self.micMeterBars,
                        color: Self.micMeterColor,
                        isActive: true
                    )
                    .frame(width: 214, height: 26)
                }
                .frame(width: Self.columnWidth)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsMicrophone)
    }

    /// Before and during a recording: the microphone, and live text.
    private var setupOptions: some View {
        VStack(spacing: 12) {
            // Stays usable while recording: it is how the microphone is
            // brought back if it was lost along the way.
            optionSwitch(localized("include_microphone"), isOn: includeMicrophone)
                .help(localized("mic_and_system_audio_info"))

            if capture.includesMicrophone {
                Menu {
                    Picker(localized("audio_input_device"), selection: $capture.selectedMicDeviceID) {
                        Text(String(format: localized("system_default_device"), capture.defaultDeviceName))
                            .tag(AudioDeviceID?.none)
                        Divider()
                        ForEach(capture.inputDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(currentDeviceName, systemImage: "mic")
                        .lineLimit(1)
                        .frame(maxWidth: 260)
                }
                .glassAction()
                .fixedSize()
                .help(localized("audio_input_device"))
            }

            // Offered when a model for live text is installed; the microphone
            // recording screen is where one can be fetched.
            if let liveModelId {
                optionSwitch("\(localized("live_text")) · \(modelManager.displayName(for: liveModelId))", isOn: $liveEnabled)
                    .disabled(capture.isCapturing)
            }
        }
        .frame(width: Self.columnWidth)
    }

    /// A labelled switch that fills the column, so stacked switches line up.
    private func optionSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(.primaryAccent)
    }

    private var currentDeviceName: String {
        if let id = capture.selectedMicDeviceID, let device = capture.inputDevices.first(where: { $0.id == id }) {
            return device.name
        }
        return capture.defaultDeviceName.isEmpty ? localized("microphone") : capture.defaultDeviceName
    }

    /// macOS has not allowed capturing system audio: say what to do about it.
    private var permissionNotice: some View {
        VStack(spacing: 14) {
            Text(localized("system_audio_permission_message"))
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            Button {
                openPrivacySettings("Privacy_ScreenCapture")
            } label: {
                Label(localized("open_system_settings"), systemImage: "gearshape")
            }
            .glassAction()
        }
    }

    /// After a recording: listen back, redo, or transcribe.
    private var finishedActions: some View {
        VStack(spacing: 16) {
            Button {
                transcribe()
            } label: {
                Label(localized("transcribe"), systemImage: "waveform")
                    .frame(minWidth: 180)
            }
            .prominentAction()
            .keyboardShortcut(.defaultAction)

            HStack(spacing: 12) {
                Button(action: togglePlayback) {
                    Label(isPlaying ? localized("pause") : localized("play"), systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .glassAction()

                Button {
                    startOver()
                } label: {
                    Label(localized("start_over"), systemImage: "arrow.counterclockwise")
                }
                .glassAction()
            }
        }
    }

    // MARK: - Actions

    private func reportUnsavedWork() {
        guard !handedOff else { return }
        if capture.isCapturing {
            appState.unsavedWork = .recordingInProgress
        } else if capture.hasRecording {
            appState.unsavedWork = .untranscribedRecording
        } else {
            appState.unsavedWork = nil
        }
    }

    private func toggleCapture() {
        if capture.isCapturing {
            // Live text is finished where `isCapturing` is observed
            capture.stopCapture()
            return
        }
        guard !capture.hasRecording, !isStarting else { return }
        stopPlayback()
        live.reset()
        systemLevels.reset()
        micLevels.reset()

        // Attach live text before the first buffer so nothing is missed;
        // audio is buffered while the model loads.
        if liveEnabled, let liveModelId {
            let sink = live.start(modelId: liveModelId, languageCode: languageManager.selectedLanguage.code)
            capture.setLiveSink(sink)
        }
        isStarting = true
        startTask = Task {
            // Starts monitoring first if it is not running
            let started = await capture.startCapture()
            isStarting = false
            guard !started else { return }
            capture.setLiveSink(nil)
            live.reset()
            if capture.permissionDenied {
                showScreenPermissionAlert = true
            }
        }
    }

    private func startOver() {
        stopPlayback()
        live.reset()
        capture.deleteRecording()
        systemLevels.reset()
        micLevels.reset()
        // The stream may have ended while the recording was on screen
        // ("Stop Sharing" in the menu bar): bring the meters back.
        monitoringRequest += 1
    }

    private func transcribe() {
        guard let url = capture.recordingURL else { return }
        stopPlayback()
        handedOff = true
        appState.transcribeRecording(at: url)
    }

    private var includeMicrophone: Binding<Bool> {
        Binding(
            get: { capture.includesMicrophone },
            set: { include in
                if include {
                    requestMicrophone()
                } else {
                    capture.setMicrophoneIncluded(false)
                }
            }
        )
    }

    /// Turns the microphone on once macOS allows it.
    private func requestMicrophone() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            capture.setMicrophoneIncluded(true)
        case .denied:
            showMicPermissionAlert = true
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        capture.setMicrophoneIncluded(true)
                    } else {
                        showMicPermissionAlert = true
                    }
                }
            }
        @unknown default:
            break
        }
    }

    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        guard let url = capture.recordingURL else { return }
        // Keep one player per recording so pause/resume continues in place
        if player?.url != url {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        }
        guard let player, player.play() else {
            capture.errorMessage = localized("playback_unavailable")
            return
        }
        isPlaying = true
        watchPlayback(of: player)
    }

    private func watchPlayback(of player: AVAudioPlayer) {
        Task { @MainActor in
            while self.player === player, player.isPlaying {
                try? await Task.sleep(for: .milliseconds(120))
            }
            if self.player === player { isPlaying = false }
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
