import SwiftUI
import TranscribeKit

/// Settings: app appearance/language, local model management (download/
/// delete only — model *selection* happens on the home screen and in the
/// AI sheet), and the Berget cloud catalog.
struct ModelsView: View {
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var bergetCatalog = BergetModelCatalog.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel = "kb_whisper-small-coreml"
    @AppStorage("appColorScheme") private var appColorScheme = "dark"
    @AppStorage("iosLLMEnabled") private var llmEnabled = true
    @AppStorage("iosSelectedLLM") private var selectedLLM = "e2b"
    @ObservedObject private var llmDownloads = LLMDownloadManager.shared
    @State private var bergetKey = KeychainHelper.get("bergetAPIKey") ?? ""

    private let models = ModelManager.kbModels + ModelManager.nbModels

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text(localized("ios_app_section"))
            } footer: {
                // Applies to both transcription and language models below
                Text(localized("ios_models_footnote"))
            }

            Section {
                ForEach(models, id: \.self) { model in
                    transcriptionModelRow(model)
                }
            } header: {
                Text(localized("ios_local_transcription_models"))
            }

            Section {
                Toggle(localized("ios_enable_llm"), isOn: $llmEnabled)
                if llmEnabled {
                    ForEach(LocalLLMModel.all) { model in
                        localLLMRow(model)
                    }
                }
            } header: {
                Text(localized("ios_local_llm_models"))
            }

            Section {
                Text(localized("ios_cloud_hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                SecureField(localized("ios_api_key"), text: $bergetKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: bergetKey) { _, newValue in
                        // Empty value deletes the stored item
                        _ = KeychainHelper.set(newValue, forKey: "bergetAPIKey")
                    }
                    .onSubmit { refreshCatalog() }

                if !bergetKey.isEmpty {
                    if !bergetCatalog.asrModels.isEmpty {
                        subheader(localized("ios_berget_asr_header"))
                        ForEach(bergetCatalog.asrModels) { model in
                            bergetRow(name: modelManager.displayName(for: "berget:\(model.id)"),
                                      isStable: model.isStable)
                        }
                    }
                    if llmEnabled && !bergetCatalog.llmModels.isEmpty {
                        subheader(localized("ios_berget_llm_header"))
                        ForEach(bergetCatalog.llmModels) { model in
                            bergetRow(name: model.name, isStable: model.isStable)
                        }
                    }
                }
            } header: {
                Text(localized("ios_berget_section"))
            }
            .task { refreshCatalog() }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label(localized("ios_about"), systemImage: "info.circle")
                }
            }
        }
        .onAppear { llmDownloads.refresh() }
        .scrollContentBackground(.hidden)
        .background(Color.surfaceBackground)
        .navigationTitle(localized("ios_settings"))
    }

    private func refreshCatalog() {
        guard !bergetKey.isEmpty else { return }
        let key = bergetKey
        Task { await bergetCatalog.refresh(apiKey: key) }
    }

    private func subheader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(.textSecondary)
            .textCase(.uppercase)
            .listRowSeparator(.hidden, edges: .top)
    }

    // MARK: - Rows

    @ViewBuilder
    private func transcriptionModelRow(_ model: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelManager.displayName(for: model))
                Text(modelManager.getModelSizeString(model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if modelManager.isModelDownloaded(model) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.primaryAccent)
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
            if modelManager.isModelDownloaded(model) {
                Button(role: .destructive) {
                    modelManager.deleteModel(model)
                    // Don't leave the home picker pointing at deleted weights
                    if selectedModel == model {
                        selectedModel = "kb_whisper-small-coreml"
                    }
                } label: {
                    Label(localized("ios_delete"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func localLLMRow(_ model: LocalLLMModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = llmDownloads.progress[model.id] {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if llmDownloads.downloaded.contains(model.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.primaryAccent)
            } else {
                Button {
                    llmDownloads.download(model)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) {
            if llmDownloads.downloaded.contains(model.id) {
                Button(role: .destructive) {
                    llmDownloads.delete(model)
                    if selectedLLM == model.id {
                        selectedLLM = "e2b"
                    }
                } label: {
                    Label(localized("ios_delete"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func bergetRow(name: String, isStable: Bool) -> some View {
        HStack {
            Image(systemName: "cloud")
                .foregroundColor(.textSecondary)
            Text(name)
            if !isStable {
                Text(localized("ios_eval_badge"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }
}
