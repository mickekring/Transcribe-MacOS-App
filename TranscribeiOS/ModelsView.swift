import SwiftUI
import TranscribeKit

/// Model management and transcription settings: download/delete KB & NB
/// models, pick the default, language, and diarization default.
struct ModelsView: View {
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var bergetCatalog = BergetModelCatalog.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel = "kb_whisper-small-coreml"
    @AppStorage("appColorScheme") private var appColorScheme = "dark"
    @AppStorage("iosLLMEnabled") private var llmEnabled = true
    @AppStorage("iosSelectedLLM") private var selectedLLM = "e2b"
    @State private var bergetKey = KeychainHelper.get("bergetAPIKey") ?? ""
    @State private var llmDownloadProgress: [String: Double] = [:]
    @State private var downloadedLLMs: Set<String> = []

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
                SecureField(localized("ios_api_key"), text: $bergetKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: bergetKey) { _, newValue in
                        // Empty value deletes the stored item
                        _ = KeychainHelper.set(newValue, forKey: "bergetAPIKey")
                    }
                    .onSubmit { refreshCatalog() }

                if !bergetKey.isEmpty {
                    ForEach(bergetCatalog.asrModels) { model in
                        cloudModelRow(model)
                    }
                }
            } header: {
                Text(localized("ios_cloud_models"))
            } footer: {
                Text(localized("ios_cloud_hint"))
            }
            .task { refreshCatalog() }

            Section {
                Toggle(localized("ios_enable_llm"), isOn: $llmEnabled)
                if llmEnabled {
                    ForEach(LocalLLMModel.all) { model in
                        localLLMRow(model)
                    }
                    if !bergetKey.isEmpty {
                        ForEach(bergetCatalog.llmModels) { model in
                            bergetLLMRow(model)
                        }
                    }
                }
            } header: {
                Text(localized("ios_ai_section"))
            } footer: {
                if llmEnabled {
                    Text(localized("ios_llm_local_models_note"))
                }
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label(localized("ios_about"), systemImage: "info.circle")
                }
            }
        }
        .onAppear { refreshDownloadedLLMs() }
        .scrollContentBackground(.hidden)
        .background(Color.surfaceBackground)
        .navigationTitle(localized("ios_settings"))
    }

    private func refreshDownloadedLLMs() {
        downloadedLLMs = Set(LocalLLMModel.all.filter(\.isDownloaded).map(\.id))
    }

    private func downloadLLM(_ model: LocalLLMModel) {
        llmDownloadProgress[model.id] = 0
        Task {
            do {
                _ = try await LLMRuntime.loadContainer(repo: model.repo) { fraction in
                    Task { @MainActor in llmDownloadProgress[model.id] = fraction }
                }
                // Downloaded and verified loadable; free the memory — the
                // summarize view loads the selected model on demand.
                LLMRuntime.release()
            } catch {
                // Row falls back to the download button on failure
            }
            llmDownloadProgress[model.id] = nil
            refreshDownloadedLLMs()
        }
    }

    @ViewBuilder
    private func localLLMRow(_ model: LocalLLMModel) -> some View {
        HStack {
            Image(systemName: "cpu")
                .foregroundColor(.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = llmDownloadProgress[model.id] {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if downloadedLLMs.contains(model.id) {
                if selectedLLM == model.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.primaryAccent)
                } else {
                    Button(localized("ios_use_model")) { selectedLLM = model.id }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                Button {
                    downloadLLM(model)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) {
            if downloadedLLMs.contains(model.id) && selectedLLM != model.id {
                Button(role: .destructive) {
                    model.delete()
                    refreshDownloadedLLMs()
                } label: {
                    Label(localized("ios_delete"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func bergetLLMRow(_ model: BergetModel) -> some View {
        let modelId = "berget:\(model.id)"
        HStack {
            Image(systemName: "cloud")
                .foregroundColor(.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                if !model.isStable {
                    Text(localized("ios_eval_badge"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if selectedLLM == modelId {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.primaryAccent)
            } else {
                Button(localized("ios_use_model")) { selectedLLM = modelId }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func refreshCatalog() {
        guard !bergetKey.isEmpty else { return }
        let key = bergetKey
        Task { await bergetCatalog.refresh(apiKey: key) }
    }

    @ViewBuilder
    private func cloudModelRow(_ model: BergetModel) -> some View {
        let modelId = "berget:\(model.id)"
        HStack {
            Image(systemName: "cloud")
                .foregroundColor(.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(modelManager.displayName(for: modelId))
                if !model.isStable {
                    Text(localized("ios_eval_badge"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if selectedModel == modelId {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.primaryAccent)
            } else {
                Button(localized("ios_use_model")) { selectedModel = modelId }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
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
