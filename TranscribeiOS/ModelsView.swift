import SwiftUI
import TranscribeKit

/// Model management and transcription settings: download/delete KB & NB
/// models, pick the default, language, and diarization default.
struct ModelsView: View {
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel = "kb_whisper-small-coreml"
    @AppStorage("appColorScheme") private var appColorScheme = "dark"

    private let models = ModelManager.kbModels + ModelManager.nbModels

    var body: some View {
        Form {
            Section(localized("ios_app_section")) {
                Picker(localized("ios_theme"), selection: $appColorScheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                Picker(localized("ios_app_language"), selection: $localization.appLanguage) {
                    Text("Svenska").tag("sv")
                    Text("Norsk").tag("no")
                    Text("English").tag("en")
                }
            }

            Section(localized("ios_models")) {
                ForEach(models, id: \.self) { model in
                    modelRow(model)
                }
            }

            Section {
                Text(localized("ios_models_footnote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label(localized("ios_about"), systemImage: "info.circle")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.surfaceBackground)
        .navigationTitle(localized("ios_settings"))
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
                        .foregroundColor(.primaryAccent)
                } else {
                    Button(localized("ios_use_model")) { selectedModel = model }
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
                    Label(localized("ios_delete"), systemImage: "trash")
                }
            }
        }
    }
}
