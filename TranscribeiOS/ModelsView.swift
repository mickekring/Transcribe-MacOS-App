import SwiftUI
import TranscribeKit

/// Model management and transcription settings: download/delete KB & NB
/// models, pick the default, language, and diarization default.
struct ModelsView: View {
    @ObservedObject private var modelManager = ModelManager.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel = "kb_whisper-small-coreml"
    @AppStorage("iosDiarize") private var diarize = true
    @AppStorage("iosLanguage") private var language = "sv"

    private let models = ModelManager.kbModels + ModelManager.nbModels

    var body: some View {
        Form {
            Section("Transkribering") {
                Picker("Språk", selection: $language) {
                    Text("Svenska").tag("sv")
                    Text("Norska").tag("no")
                    Text("Engelska").tag("en")
                    Text("Automatiskt").tag("auto")
                }
                Toggle("Identifiera talare", isOn: $diarize)
            }

            Section("Modeller") {
                ForEach(models, id: \.self) { model in
                    modelRow(model)
                }
            }

            Section {
                Text("Modellerna körs helt lokalt på telefonens Neural Engine. Första gången en modell används byggs en cache — det kan ta flera minuter beroende på modellstorlek.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Modeller")
    }

    @ViewBuilder
    private func modelRow(_ model: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelManager.displayName(for: model))
                Text(modelManager.getModelSizeString(model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if modelManager.isModelDownloaded(model) {
                if selectedModel == model {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Använd") { selectedModel = model }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else if modelManager.isDownloading[model] == true {
                HStack(spacing: 8) {
                    ProgressView(value: modelManager.downloadProgress[model] ?? 0)
                        .frame(width: 60)
                    Text("\(Int((modelManager.downloadProgress[model] ?? 0) * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        WhisperKitService.shared.cancelDownload(modelId: model)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    Task { try? await WhisperKitService.shared.downloadOnly(modelId: model) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) {
            if modelManager.isModelDownloaded(model) && selectedModel != model {
                Button(role: .destructive) {
                    modelManager.deleteModel(model)
                } label: {
                    Label("Ta bort", systemImage: "trash")
                }
            }
        }
    }
}
