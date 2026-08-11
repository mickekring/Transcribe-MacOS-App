import SwiftUI
import AVFoundation
import TranscribeKit

/// Milestone-1 spike: prove KB Whisper + diarization run on-device on iPhone.
/// Measures model load time (ANE specialization on first run), transcription
/// wall time, and real-time factor. Not the product UI.
struct SpikeView: View {
    @ObservedObject private var modelManager = ModelManager.shared

    @State private var selectedModel = "kb_whisper-small-coreml"
    @State private var showImporter = false
    @State private var pickedFile: URL?
    @State private var transcript = ""
    @State private var speakerLines: [String] = []
    @State private var status = ""
    @State private var isWorking = false
    @State private var diarize = false

    @State private var loadSeconds: Double?
    @State private var transcribeSeconds: Double?
    @State private var audioSeconds: Double?

    private let kbModels = ModelManager.kbModels

    var body: some View {
        NavigationStack {
            Form {
                Section("Modell") {
                    Picker("KB Whisper", selection: $selectedModel) {
                        ForEach(kbModels, id: \.self) { id in
                            Text(modelManager.displayName(for: id)).tag(id)
                        }
                    }
                    if modelManager.isModelDownloaded(selectedModel) {
                        Label("Nedladdad", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if modelManager.isDownloading[selectedModel] == true {
                        ProgressView(value: modelManager.downloadProgress[selectedModel] ?? 0) {
                            Text("Laddar ner… \(Int((modelManager.downloadProgress[selectedModel] ?? 0) * 100))%")
                        }
                    } else {
                        Button("Ladda ner (\(modelManager.getModelSizeString(selectedModel)))") {
                            download()
                        }
                    }
                }

                Section("Ljudfil") {
                    Button(pickedFile?.lastPathComponent ?? "Välj ljudfil…") {
                        showImporter = true
                    }
                    Toggle("Identifiera talare", isOn: $diarize)
                    Button("Transkribera") { transcribe() }
                        .disabled(pickedFile == nil || isWorking
                                  || !modelManager.isModelDownloaded(selectedModel))
                }

                if isWorking || !status.isEmpty {
                    Section("Status") {
                        HStack {
                            if isWorking { ProgressView().padding(.trailing, 8) }
                            Text(status)
                        }
                    }
                }

                if let load = loadSeconds {
                    Section("Mätvärden") {
                        LabeledContent("Modelladdning", value: String(format: "%.1f s", load))
                        if let t = transcribeSeconds {
                            LabeledContent("Transkribering", value: String(format: "%.1f s", t))
                        }
                        if let t = transcribeSeconds, let a = audioSeconds, a > 0 {
                            LabeledContent("Realtidsfaktor", value: String(format: "%.2fx", a / t))
                        }
                    }
                }

                if !transcript.isEmpty {
                    Section("Transkription") {
                        Text(transcript)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }

                if !speakerLines.isEmpty {
                    Section("Talare") {
                        ForEach(speakerLines, id: \.self) { line in
                            Text(line).font(.callout.monospacedDigit())
                        }
                    }
                }
            }
            .navigationTitle("Transcribe-spike")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result {
                    importFile(url)
                }
            }
        }
    }

    /// Copies the picked file into our temp dir — the security-scoped URL from
    /// the document picker is not valid for the duration of a long transcription.
    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe/Import", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            pickedFile = dest
            audioSeconds = nil
        } catch {
            status = "Kunde inte läsa filen: \(error.localizedDescription)"
        }
    }

    private func download() {
        let model = selectedModel
        status = ""
        Task {
            do {
                try await WhisperKitService.shared.downloadOnly(modelId: model)
            } catch {
                status = "Nedladdning misslyckades: \(error.localizedDescription)"
            }
        }
    }

    private func transcribe() {
        guard let file = pickedFile else { return }
        let model = selectedModel
        isWorking = true
        transcript = ""
        speakerLines = []
        transcribeSeconds = nil
        status = "Laddar modell… (första gången byggs ANE-cachen, det kan ta flera minuter)"

        Task {
            do {
                let asset = AVURLAsset(url: file)
                if let duration = try? await asset.load(.duration) {
                    audioSeconds = CMTimeGetSeconds(duration)
                }

                let loadStart = Date()
                try await WhisperKitService.shared.initialize(modelId: model)
                loadSeconds = Date().timeIntervalSince(loadStart)

                status = "Transkriberar…"
                let start = Date()
                for try await update in WhisperKitService.shared.transcribe(
                    fileURL: file, modelId: model, language: "sv") {
                    transcript = update.text
                    status = "Transkriberar… \(Int(update.progress * 100))%"
                    if update.isComplete {
                        transcribeSeconds = Date().timeIntervalSince(start)
                    }
                }

                if diarize {
                    status = "Identifierar talare…"
                    let turns = try await DiarizationService.shared.diarize(fileURL: file)
                    speakerLines = turns.map { turn in
                        String(format: "Talare %d  %.1f–%.1f s",
                               turn.speakerId + 1, turn.start, turn.end)
                    }
                }
                status = "Klar"
            } catch {
                status = "Fel: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }
}
