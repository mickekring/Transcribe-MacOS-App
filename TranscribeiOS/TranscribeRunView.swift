import SwiftUI
import AVFoundation
import TranscribeKit

struct AudioJob: Identifiable {
    let id = UUID()
    let url: URL
    /// Suggested record title (recording name or imported file name)
    let title: String
}

/// Runs the transcription pipeline over one audio file with progress, then
/// saves the result into the library. Presented full-screen so the phone
/// stays awake and the user sees where the minutes go.
struct TranscribeRunView: View {
    let job: AudioJob
    @ObservedObject var store: TranscriptStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = LocalizationManager.shared

    @AppStorage("selectedTranscriptionModel") private var selectedModel = "kb_whisper-small-coreml"
    @AppStorage("iosDiarize") private var diarize = true
    @AppStorage("iosLanguage") private var language = "sv"

    @State private var status = ""
    @State private var statusInfo = ""
    @State private var progress: Double = 0
    @State private var transcript = ""
    @State private var isDone = false
    @State private var failed = false
    @State private var rtf: Double?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if !isDone {
                    ProgressView(value: progress > 0 ? progress : nil)
                        .progressViewStyle(.linear)
                        .padding(.horizontal)
                }
                HStack(spacing: 10) {
                    if !isDone && !failed { AccentSpinner(size: 18) }
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(failed ? .red : .secondary)
                }
                if !statusInfo.isEmpty {
                    Text(statusInfo)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                if let rtf {
                    Text(String(format: localized("ios_realtime_factor"), String(format: "%.2f", rtf)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(transcript)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                // Follow the growing transcript (chat-style); a manual
                // scroll up releases the bottom anchor until scrolled back.
                .defaultScrollAnchor(.bottom)

                if isDone || failed {
                    Button(isDone ? localized("ios_done") : localized("ios_close")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surfaceBackground)
            .navigationTitle(job.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isDone && !failed {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(localized("cancel")) {
                            WhisperKitService.shared.cancelTranscription()
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(!isDone && !failed)
            .task { await run() }
        }
    }

    private func run() async {
        // Keep the screen awake for the duration — a locked phone suspends
        // the app and the transcription with it.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            let asset = AVURLAsset(url: job.url)
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0

            // Two distinct waits, two distinct messages: loading an already-
            // optimized model into memory takes seconds; the first-ever load
            // of a model builds the Neural Engine cache and takes minutes.
            // Same heuristic as the Mac app: a load running past 10s means
            // the cache is being built.
            let modelName = ModelManager.shared.displayName(for: selectedModel)
            status = String(format: localized("ios_loading_model_memory"), modelName)
            statusInfo = localized("ios_loading_model_info")
            let loadStart = Date()
            let heartbeat = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                while !Task.isCancelled {
                    let elapsed = Int(Date().timeIntervalSince(loadStart))
                    let clock = elapsed >= 60
                        ? "\(elapsed / 60) min \(elapsed % 60) s"
                        : "\(elapsed) s"
                    status = String(format: localized("ios_optimizing_model"), modelName, clock)
                    statusInfo = localized("ios_optimizing_info")
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            do {
                try await WhisperKitService.shared.initialize(modelId: selectedModel)
                heartbeat.cancel()
            } catch {
                heartbeat.cancel()
                throw error
            }
            statusInfo = ""

            status = localized("ios_transcribing")
            let start = Date()
            var segments: [TranscriptionSegmentData] = []
            for try await update in WhisperKitService.shared.transcribe(
                fileURL: job.url,
                modelId: selectedModel,
                language: language == "auto" ? nil : language
            ) {
                transcript = update.text
                progress = update.progress
                status = String(format: localized("ios_transcribing_pct"), Int(update.progress * 100))
                if update.isComplete {
                    segments = update.segments
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            if duration > 0, elapsed > 0 { rtf = duration / elapsed }

            var turns: [SpeakerTurn]? = nil
            if diarize {
                status = localized("ios_identifying_speakers")
                turns = try await DiarizationService.shared.diarize(fileURL: job.url) { p in
                    Task { @MainActor in progress = p }
                }
            }

            let record = TranscriptRecord(
                id: UUID(),
                title: job.title,
                date: Date(),
                audioFileName: job.url.lastPathComponent,
                duration: duration,
                modelId: selectedModel,
                text: transcript,
                segments: segments,
                turns: turns,
                speakerNames: [:]
            )
            store.add(record)
            status = localized("ios_done_saved")
            isDone = true
        } catch {
            status = String(format: localized("ios_error"), error.localizedDescription)
            failed = true
        }
    }
}
