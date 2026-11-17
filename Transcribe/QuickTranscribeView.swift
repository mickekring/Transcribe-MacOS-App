import SwiftUI
import TranscribeKit
import AVFoundation

/// A small window for dictating a few sentences and copying the text.
/// It works offline: only a model that is already on disk is ever used.
struct QuickTranscribeView: View {
    @StateObject private var recorder = AudioRecorder()
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel: String = "kb_whisper-small-coreml"
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    @State private var phase: Phase = .idle
    @State private var transcriptionText = ""
    /// The text as last copied; anything else is lost when the app quits.
    @State private var copiedText = ""
    /// What the engine is doing before any text arrives (loading the model, …).
    @State private var statusMessage = ""
    /// The last recording was transcribed and contained no speech.
    @State private var foundNoSpeech = false
    @State private var errorMessage: String?
    @State private var levels = LevelHistory(capacity: Self.meterBars)
    @State private var elapsed: TimeInterval = 0
    @State private var meterTask: Task<Void, Never>?
    @State private var transcriptionTask: Task<Void, Never>?

    private static let meterBars = 44

    private enum Phase {
        case idle
        case recording
        case transcribing
    }

    private var preferredScheme: ColorScheme? {
        switch appColorScheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    /// The model a recording would be transcribed with right now.
    ///
    /// Quick Transcribe neither downloads nor uses the cloud, so the selected
    /// model counts only if it is local and on disk. Otherwise a downloaded
    /// model that handles the chosen language stands in: a Parakeet-family
    /// one (fast) before a Whisper one.
    private var modelId: String? {
        let downloaded = ModelManager.allLocalModels.filter { modelManager.isModelDownloaded($0) }
        if downloaded.contains(selectedModel) { return selectedModel }
        let language = languageManager.selectedLanguage.code
        let capable = downloaded.filter { ModelManager.supports(languageCode: language, modelId: $0) }
        return capable.first { ModelManager.engine(for: $0) == .parakeet }
            ?? capable.first { ModelManager.engine(for: $0) == .whisperKit }
            ?? downloaded.first
    }

    private var hasResult: Bool {
        phase == .idle && !transcriptionText.isEmpty
    }

    /// A result that has not been copied: quitting asks first.
    private var hasUncopiedResult: Bool {
        hasResult && transcriptionText != copiedText
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            transcript
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.recordingRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            controls
        }
        .padding(16)
        .frame(minWidth: 400, idealWidth: 400, minHeight: 300, idealHeight: 300)
        // A bare NSWindow hosts this view, so it brings the app's backdrop
        // with it: the palette's text colours are tuned for that surface,
        // not for the system window background.
        .background { AuroraBackdrop(intensity: 0.4) }
        .preferredColorScheme(preferredScheme)
        .onChange(of: hasUncopiedResult, initial: true) { _, uncopied in
            AppState.shared.quickTranscriptUnsaved = uncopied
        }
        .onChange(of: recorder.stoppedByError) { _, stopped in
            guard stopped, phase == .recording else { return }
            meterTask?.cancel()
            recorder.discard()
            phase = .idle
            errorMessage = localized("recording_write_failed")
        }
        .onDisappear {
            meterTask?.cancel()
            transcriptionTask?.cancel()
            recorder.discard()
            phase = .idle
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            if let modelId {
                Label(modelManager.displayName(for: modelId), systemImage: ContentView.icon(for: modelId))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .help(localized("quick_local_note"))
                    .accessibilityLabel("\(localized("model")): \(modelManager.displayName(for: modelId))")
                    .accessibilityHint(localized("quick_local_note"))
            }
            Spacer(minLength: 8)
            switch phase {
            case .idle:
                EmptyView()
            case .recording:
                StatusBadge(text: localized("recording_in_progress"), color: .recordingRed, isPulsing: true)
                Text(formatClock(elapsed, tenths: false))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityLabel(localized("recording_duration"))
                    .accessibilityValue(formatClock(elapsed, tenths: false))
            case .transcribing:
                StatusBadge(text: localized("transcribing"), color: .primaryAccent, isPulsing: true)
            }
        }
        .frame(height: 18)
    }

    private var transcript: some View {
        Group {
            if phase == .recording {
                WaveformMeter(levels: levels.levels, barCount: Self.meterBars, color: .recordingRed)
                    .frame(height: 44)
                    .padding(.horizontal, 20)
            } else if !transcriptionText.isEmpty {
                ScrollView {
                    Text(transcriptionText)
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                // Read from the top; follow the newest words once it overflows
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
            } else {
                placeholder
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentCard()
    }

    /// What the card says when it holds no transcript.
    @ViewBuilder
    private var placeholder: some View {
        if phase == .transcribing {
            HStack(spacing: 10) {
                AccentSpinner(size: 16, lineWidth: 2)
                Text(statusMessage.isEmpty ? localized("transcribing") : statusMessage)
            }
        } else if modelId == nil {
            VStack(spacing: 10) {
                Text(localized("quick_no_local_model"))
                Button(localized("menu_settings")) {
                    NSApp.activate()
                    SceneActions.shared.openSettings?()
                }
                .glassAction()
            }
        } else if foundNoSpeech {
            // Same symbol and wording as the transcription screen's empty result
            VStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .font(.title2)
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityHidden(true)
                Text(localized("no_speech_detected"))
            }
        } else {
            Text(localized("quick_placeholder"))
        }
    }

    private var controls: some View {
        // The record button is centred on its own; copy and clear sit at the
        // edges only while there is a transcript to act on
        ZStack {
            primaryButton

            if hasResult {
                HStack {
                    Button(action: copyToClipboard) {
                        Label(localized("copy_text"), systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .glassAction()
                    .help(localized("copy_text"))
                    .accessibilityLabel(localized("copy_text"))

                    Spacer()

                    Button(action: clearTranscription) {
                        Label(localized("clear"), systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .glassAction()
                    .help(localized("clear"))
                    .accessibilityLabel(localized("clear"))
                }
            }
        }
    }

    /// Record, stop, or — while a recording is being transcribed — cancel.
    private var primaryButton: some View {
        let symbol: String
        let label: String
        let symbolColor: Color
        let glass: Glass
        switch phase {
        case .idle:
            symbol = "mic.fill"
            label = localized("start_recording")
            symbolColor = .onAccent
            glass = .regular.tint(Color.primaryAccent).interactive()
        case .recording:
            symbol = "stop.fill"
            label = localized("stop_recording")
            symbolColor = .white
            glass = .regular.tint(Color.recordingRed).interactive()
        case .transcribing:
            symbol = "xmark"
            label = localized("cancel")
            symbolColor = .textPrimary
            glass = .regular.interactive()
        }
        let unavailable = phase == .idle && modelId == nil

        return Button(action: primaryAction) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(symbolColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .circle)
        .disabled(unavailable)
        .opacity(unavailable ? 0.45 : 1)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Actions

    private func primaryAction() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .transcribing: cancelTranscription()
        }
    }

    private func startRecording() {
        errorMessage = nil
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            errorMessage = localized("mic_permission_message")
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        beginRecording()
                    } else {
                        errorMessage = localized("mic_permission_message")
                    }
                }
            }
        @unknown default:
            break
        }
    }

    private func beginRecording() {
        guard phase == .idle else { return }
        do {
            try recorder.start()
        } catch AudioRecorder.StartError.refused {
            errorMessage = localized("ios_recording_failed")
            return
        } catch {
            errorMessage = String(format: localized("mic_start_failed"), error.localizedDescription)
            return
        }
        transcriptionText = ""
        foundNoSpeech = false
        levels.reset()
        elapsed = 0
        phase = .recording

        meterTask?.cancel()
        meterTask = Task {
            while !Task.isCancelled {
                levels.append(recorder.level)
                elapsed = recorder.currentTime
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stopRecording() {
        meterTask?.cancel()
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        transcribe(url)
    }

    private func transcribe(_ url: URL) {
        guard let modelId else {
            // The last local model was removed during the recording; the
            // card now explains what is missing
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            return
        }
        phase = .transcribing
        statusMessage = ""
        errorMessage = nil
        let language = languageManager.selectedLanguage.code

        transcriptionTask = Task {
            // The clip exists only to be transcribed
            defer { try? FileManager.default.removeItem(at: url) }

            // Straight to the engine that owns the model: TranscriptionService
            // follows the toolbar selection, which may be a cloud model
            let updates: AsyncThrowingStream<TranscriptionUpdate, Error>
            if ModelManager.engine(for: modelId) == .parakeet {
                updates = ParakeetService.shared.transcribe(fileURL: url, modelId: modelId, language: language)
            } else {
                updates = WhisperKitService.shared.transcribe(fileURL: url, modelId: modelId, language: language)
            }

            do {
                var finalText: String?
                for try await update in updates {
                    if update.isComplete {
                        finalText = update.text
                        break
                    }
                    // Low-progress updates are status messages (model loading,
                    // init, etc.), and WhisperKit sends its "Transcribing…"
                    // placeholder as text until the first words arrive
                    if update.progress < 0.15 {
                        statusMessage = update.text
                    } else if update.text != localized("transcribing") {
                        transcriptionText = update.text
                    }
                }
                try Task.checkCancellation()
                let text = (finalText ?? transcriptionText).trimmingCharacters(in: .whitespacesAndNewlines)
                transcriptionText = text
                foundNoSpeech = text.isEmpty
            } catch {
                // A cancelled run has already been reset by whoever cancelled it
                guard !Task.isCancelled else { return }
                transcriptionText = ""
                errorMessage = error.localizedDescription
            }
            phase = .idle
        }
    }

    private func cancelTranscription() {
        // Ending the stream stops the engine's inference
        transcriptionTask?.cancel()
        transcriptionText = ""
        statusMessage = ""
        phase = .idle
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptionText, forType: .string)
        copiedText = transcriptionText
    }

    private func clearTranscription() {
        transcriptionText = ""
        foundNoSpeech = false
        errorMessage = nil
    }
}

/// Records the clip for Quick Transcribe to a temporary file.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum StartError: Error {
        /// The recorder was created but would not start.
        case refused
    }

    /// The running recording ended on its own: the encoder or the disk failed.
    @Published private(set) var stoppedByError = false

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    /// Starts recording to a temporary file, or throws the reason it could not.
    func start() throws {
        // macOS doesn't require AVAudioSession configuration
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe")
            .appendingPathComponent("QuickRecordings")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)

        let url = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.delegate = self
        newRecorder.isMeteringEnabled = true
        guard newRecorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw StartError.refused
        }
        stoppedByError = false
        audioRecorder = newRecorder
        recordingURL = url
    }

    /// Stops recording and returns the file, if there was a recording.
    func stop() -> URL? {
        audioRecorder?.stop()
        audioRecorder = nil
        defer { recordingURL = nil }
        return recordingURL
    }

    /// Stops recording and deletes the file.
    func discard() {
        if let url = stop() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Input level in 0…1, mapped from −60…0 dBFS like the main recorder's meter.
    var level: Float {
        guard let audioRecorder, audioRecorder.isRecording else { return 0 }
        audioRecorder.updateMeters()
        return max(0, min(1, (audioRecorder.averagePower(forChannel: 0) + 60) / 60))
    }

    var currentTime: TimeInterval {
        audioRecorder?.currentTime ?? 0
    }

    // MARK: AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.recordingFailed(id) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.recordingFailed(id) }
    }

    private func recordingFailed(_ id: ObjectIdentifier) {
        // Ignore a late callback from a recording that was already stopped
        guard let audioRecorder, ObjectIdentifier(audioRecorder) == id else { return }
        stoppedByError = true
    }
}
