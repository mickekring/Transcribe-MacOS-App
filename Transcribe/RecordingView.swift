import SwiftUI
import Combine
import TranscribeKit
import AVFoundation
import CoreAudio

/// Microphone recording, with live text when a Parakeet-family model is available.
struct RecordingView: View {
    @StateObject private var capture = MicrophoneCapture()
    @StateObject private var live = LiveTranscriptController()
    @EnvironmentObject var appState: AppState
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel: String = "kb_whisper-small-coreml"
    @AppStorage("liveTranscriptionEnabled") private var liveEnabled = true

    @State private var levels = LevelHistory()
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var showPermissionAlert = false
    @State private var showRecordingError = false
    /// The recording was passed to the transcription screen and must survive this view.
    @State private var handedOff = false

    private let meterTick = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

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
                LiveTranscriptPanel(live: live, isRecording: capture.isRecording)
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
        .onAppear {
            #if DEBUG
            // Before monitoring starts, so a demo run never opens the microphone
            DebugHarness.attach(to: capture, start: { toggleRecording() }, transcribe: { transcribe() })
            #endif
            // The meter runs before recording, but only once the user has
            // allowed the microphone — opening it earlier is what prompts.
            if AVAudioApplication.shared.recordPermission == .granted {
                capture.startMonitoring()
            }
        }
        .onDisappear {
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
            levels.append(capture.audioLevel)
        }
        .onChange(of: capture.isRecording) { _, _ in reportUnsavedWork() }
        .onChange(of: capture.hasRecording) { _, _ in reportUnsavedWork() }
        .onChange(of: capture.isRecording) { wasRecording, isRecording in
            // The capture stopped on its own (device lost, disk full)
            if wasRecording && !isRecording {
                capture.setLiveSink(nil)
                Task { await live.finish() }
            }
        }
        .onChange(of: capture.errorMessage) { _, message in
            showRecordingError = message != nil
        }
        .alert(localized("mic_permission_required"), isPresented: $showPermissionAlert) {
            Button(localized("open_system_settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(localized("mic_permission_message"))
        }
        .alert(localized("recording_error"), isPresented: $showRecordingError) {
            Button("OK") { capture.errorMessage = nil }
        } message: {
            Text(capture.errorMessage ?? "")
        }
    }

    // MARK: - Controls column

    private var controls: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Text(localized("new_recording"))
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                statusBadge
            }

            recordButton

            VStack(spacing: 14) {
                Text(formatClock(capture.recordedSeconds))
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(capture.isRecording || capture.hasRecording ? Color.textPrimary : Color.textTertiary)
                    .contentTransition(.numericText())
                    .accessibilityLabel(localized("recording_duration"))
                    .accessibilityValue(formatClock(capture.recordedSeconds, tenths: false))

                WaveformMeter(
                    levels: levels.levels,
                    color: capture.isRecording ? .recordingRed : .primaryAccent,
                    isActive: capture.isRecording || !capture.hasRecording
                )
                .frame(width: 330, height: 52)
            }

            if capture.hasRecording && !capture.isRecording {
                finishedActions
            } else {
                setupOptions
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var statusBadge: some View {
        Group {
            if capture.isPausedForSleep {
                StatusBadge(text: localized("recording_paused_sleep"), color: .orange)
            } else if capture.isStarting {
                StatusBadge(text: localized("mic_starting"), color: .orange, isPulsing: true)
            } else if capture.isRecording {
                StatusBadge(text: localized("recording_in_progress"), color: .recordingRed, isPulsing: true)
            } else if capture.hasRecording {
                StatusBadge(text: localized("recording_complete"), color: .primaryAccent)
            } else {
                StatusBadge(text: localized("tap_to_record"), color: .textTertiary)
            }
        }
        .frame(height: 18)
    }

    private var recordButton: some View {
        let isRecording = capture.isRecording
        return ZStack {
            // A halo that follows the input level: direct feedback that the
            // microphone hears something, before and during recording.
            Circle()
                .fill((isRecording ? Color.recordingRed : Color.brandGreen).opacity(0.16))
                .frame(width: 150, height: 150)
                .scaleEffect(1 + CGFloat(capture.audioLevel) * 0.32)
                .animation(.easeOut(duration: 0.12), value: capture.audioLevel)
                .accessibilityHidden(true)

            Button(action: toggleRecording) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(isRecording ? Color.white : Color.onAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 124, height: 124)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(isRecording ? Color.recordingRed : Color.primaryAccent).interactive(),
                in: .circle
            )
            .disabled((capture.hasRecording && !isRecording) || capture.isStarting)
            .opacity((capture.hasRecording && !isRecording) || capture.isStarting ? 0.45 : 1)
            .keyboardShortcut(.space, modifiers: [])
            .help(isRecording ? localized("stop_recording") : localized("start_recording"))
            .accessibilityLabel(isRecording ? localized("stop_recording") : localized("start_recording"))
        }
        .frame(height: 190)
    }

    /// Before and during a recording: which microphone, and live text.
    private var setupOptions: some View {
        VStack(spacing: 12) {
            Menu {
                Picker(localized("audio_input_device"), selection: $capture.selectedDeviceID) {
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

            liveOption
        }
    }

    private var currentDeviceName: String {
        if let id = capture.selectedDeviceID, let device = capture.inputDevices.first(where: { $0.id == id }) {
            return device.name
        }
        return capture.defaultDeviceName.isEmpty ? localized("microphone") : capture.defaultDeviceName
    }

    @ViewBuilder
    private var liveOption: some View {
        if let liveModelId {
            Toggle(isOn: $liveEnabled) {
                Text("\(localized("live_text")) · \(modelManager.displayName(for: liveModelId))")
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.primaryAccent)
            .disabled(capture.isRecording)
        } else if let suggestion = suggestedLiveModel {
            if modelManager.isDownloading[suggestion] == true {
                HStack(spacing: 8) {
                    ProgressView(value: modelManager.downloadProgress[suggestion] ?? 0)
                        .frame(width: 120)
                        .tint(.primaryAccent)
                    Text("\(Int((modelManager.downloadProgress[suggestion] ?? 0) * 100)) %")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                }
            } else {
                Button {
                    Task { try? await LocalModels.download(modelId: suggestion) }
                } label: {
                    Label(
                        String(format: localized("live_get_model"), modelManager.displayName(for: suggestion), modelManager.getModelSizeString(suggestion)),
                        systemImage: "bolt"
                    )
                    .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primaryAccent)
                .pointerStyle(.link)
                .help(localized("live_unavailable_hint"))
            }
        }
    }

    /// The Parakeet-family model worth offering for live text in the chosen language.
    private var suggestedLiveModel: String? {
        let code = languageManager.selectedLanguage.code
        let effective = code == "auto" && selectedModel.hasPrefix("kb_whisper-") ? "sv" : code
        return ParakeetModelSpec.all
            .filter { effective == "auto" || $0.languageCodes.contains(effective) }
            .min { $0.languageCodes.count < $1.languageCodes.count }?
            .id
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
        if capture.isRecording {
            appState.unsavedWork = .recordingInProgress
        } else if capture.hasRecording {
            appState.unsavedWork = .untranscribedRecording
        } else {
            appState.unsavedWork = nil
        }
    }

    private func toggleRecording() {
        if capture.isRecording {
            stopRecording()
            return
        }
        #if DEBUG
        if capture.usesInjectedAudio {
            beginRecording()
            return
        }
        #endif
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            showPermissionAlert = true
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        capture.startMonitoring()
                        beginRecording()
                    } else {
                        showPermissionAlert = true
                    }
                }
            }
        @unknown default:
            break
        }
    }

    private func beginRecording() {
        stopPlayback()
        live.reset()
        levels.reset()

        // Attach live text before the first buffer so nothing is missed;
        // audio is buffered while the model loads.
        if liveEnabled, let liveModelId {
            let sink = live.start(modelId: liveModelId, languageCode: languageManager.selectedLanguage.code)
            capture.setLiveSink(sink)
        }
        Task {
            if await !capture.startRecording() {
                capture.setLiveSink(nil)
                live.reset()
            }
        }
    }

    private func stopRecording() {
        capture.stopRecording()
        capture.setLiveSink(nil)
        Task { await live.finish() }
    }

    private func startOver() {
        stopPlayback()
        live.reset()
        capture.deleteRecording()
        levels.reset()
    }

    private func transcribe() {
        guard let url = capture.recordingURL else { return }
        stopPlayback()
        handedOff = true
        appState.transcribeRecording(at: url)
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
        guard let player, player.play() else { return }
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

// MARK: - Live transcript

/// The live transcript: settled text in the primary colour, the part still
/// being revised dimmed behind it.
struct LiveTranscriptPanel: View {
    @ObservedObject var live: LiveTranscriptController
    let isRecording: Bool
    /// Shown before anything has been said.
    var idleHint: String = localized("live_idle_hint")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                StatusBadge(
                    text: live.modelName.isEmpty ? localized("live_text") : "\(localized("live_text")) · \(live.modelName)",
                    color: live.phase == .listening && isRecording ? .primaryAccent : .textTertiary,
                    isPulsing: live.phase == .listening && isRecording
                )
                Spacer()
                if live.phase == .preparing || live.phase == .finishing {
                    AccentSpinner(size: 14, lineWidth: 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(Color.borderLight)

            ScrollView {
                transcript
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            // Read from the top; once the text outgrows the panel, follow
            // the newest words.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)

            Divider().overlay(Color.borderLight)

            Text(localized("live_preview_note"))
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentCard(cornerRadius: Metrics.panelRadius)
    }

    @ViewBuilder
    private var transcript: some View {
        if case .failed(let message) = live.phase {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.textSecondary)
        } else if live.hasText {
            // One Text so settled and tentative words wrap as a single paragraph
            Text("\(Text(live.confirmed).foregroundStyle(Color.textPrimary))\(separator)\(Text(live.volatile).foregroundStyle(Color.textTertiary))")
                .font(.system(size: 17))
                .lineSpacing(6)
                .textSelection(.enabled)
                .animation(.easeOut(duration: 0.15), value: live.volatile)
        } else {
            Text(placeholder)
                .font(.system(size: 17))
                .foregroundStyle(Color.textTertiary)
        }
    }

    private var separator: String {
        guard !live.confirmed.isEmpty, !live.volatile.isEmpty, !live.confirmed.hasSuffix("\n") else { return "" }
        return " "
    }

    private var placeholder: String {
        switch live.phase {
        case .preparing: return isRecording ? localized("live_loading_model") : idleHint
        default: return isRecording ? localized("live_listening") : idleHint
        }
    }
}
