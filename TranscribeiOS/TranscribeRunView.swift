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

    @AppStorage("selectedTranscriptionModel") private var selectedModel = "kb_whisper-small-coreml"
    @AppStorage("iosDiarize") private var diarize = true
    @AppStorage("iosLanguage") private var language = "sv"

    @State private var status = ""
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
                HStack {
                    if !isDone && !failed { ProgressView() }
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(failed ? .red : .secondary)
                }
                if let rtf {
                    Text(String(format: "%.2fx realtid", rtf))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(transcript)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

                if isDone || failed {
                    Button(isDone ? "Klar" : "Stäng") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom)
                }
            }
            .navigationTitle(job.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isDone && !failed {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Avbryt") {
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

            status = "Laddar modell… (första gången kan ta flera minuter)"
            try await WhisperKitService.shared.initialize(modelId: selectedModel)

            status = "Transkriberar…"
            let start = Date()
            var segments: [TranscriptionSegmentData] = []
            for try await update in WhisperKitService.shared.transcribe(
                fileURL: job.url,
                modelId: selectedModel,
                language: language == "auto" ? nil : language
            ) {
                transcript = update.text
                progress = update.progress
                status = "Transkriberar… \(Int(update.progress * 100))%"
                if update.isComplete {
                    segments = update.segments
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            if duration > 0, elapsed > 0 { rtf = duration / elapsed }

            var turns: [SpeakerTurn]? = nil
            if diarize {
                status = "Identifierar talare…"
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
            status = "Klar och sparad"
            isDone = true
        } catch {
            status = "Fel: \(error.localizedDescription)"
            failed = true
        }
    }
}
