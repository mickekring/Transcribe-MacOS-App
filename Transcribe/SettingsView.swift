import SwiftUI
import TranscribeKit

private enum SettingsSection: String, Hashable {
    case general
    case apiKeys
    case localModels
    case cloudModels
    case llmLocal
    case llmCloud
    case prompts
}

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @StateObject private var ollama = OllamaConnection()
    @State private var selectedSection: SettingsSection = .general
    /// Held here rather than in the prompts pane, so half-written prompts
    /// survive a visit to another pane.
    @State private var promptDrafts = PromptDrafts()
    /// A download can outlive the pane that started it; its failure is
    /// reported on whichever pane is showing.
    @State private var modelDownloadError: String?
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section(localized("general")) {
                    Label(localized("general"), systemImage: "gearshape")
                        .tag(SettingsSection.general)
                    Label(localized("api_keys"), systemImage: "key")
                        .tag(SettingsSection.apiKeys)
                }
                Section(localized("transcription")) {
                    Label(localized("local_models"), systemImage: "internaldrive")
                        .tag(SettingsSection.localModels)
                    Label(localized("cloud_models"), systemImage: "cloud")
                        .tag(SettingsSection.cloudModels)
                }
                Section(localized("language_models")) {
                    Label(localized("local_models"), systemImage: "laptopcomputer")
                        .tag(SettingsSection.llmLocal)
                    Label(localized("cloud_models"), systemImage: "cloud")
                        .tag(SettingsSection.llmCloud)
                }
                Section(localized("process_text")) {
                    Label(localized("prompts"), systemImage: "text.bubble")
                        .tag(SettingsSection.prompts)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(localized("settings"))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityAddTraits(.isHeader)
            }
            // Must come before the width. With this modifier after it, an
            // off-screen render laid the column out 145 pt wide whatever
            // width was asked for, which truncates the labels.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            ScrollView {
                pane
            }
            // A fresh scroll view per pane: otherwise a pane opens scrolled
            // to wherever the previous one was left
            .id(selectedSection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A window of its own, so it brings the app's backdrop with it,
            // receded as behind the main window's working screens
            .background { AuroraBackdrop(intensity: 0.4) }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .frame(width: 1040, height: 640)
        .environmentObject(ollama)
        #if DEBUG
        .onAppear {
            // -debugSettingsSection localModels (see DebugHarness)
            if let name = UserDefaults.standard.string(forKey: "debugSettingsSection"),
               let section = SettingsSection(rawValue: name) {
                selectedSection = section
            }
        }
        #endif
        .alert(localized("model_download_failed_title"), isPresented: Binding(
            get: { modelDownloadError != nil },
            set: { if !$0 { modelDownloadError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(modelDownloadError ?? "")
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView()
        case .apiKeys:
            APIKeysView()
        case .localModels:
            LocalModelsView(downloadError: $modelDownloadError)
        case .cloudModels:
            CloudModelsView()
        case .llmLocal:
            LLMLocalModelsView()
        case .llmCloud:
            LLMCloudModelsView()
        case .prompts:
            TextProcessingPromptsView(drafts: $promptDrafts)
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var localizationManager = LocalizationManager.shared

    var body: some View {
        SettingsPane(icon: "gearshape.fill", title: localized("general")) {
            // Privacy: local-only mode disables every network feature
            SettingsCard {
                HStack {
                    CardHeading(title: localized("local_only_mode"), icon: "lock.shield")
                    Spacer()
                    Toggle(localized("local_only_mode"), isOn: $settingsManager.localOnlyMode)
                        .toggleStyle(.switch)
                        .tint(.primaryAccent)
                        .labelsHidden()
                }
                CardNote(localized("local_only_mode_description"))
            }

            // App Language
            SettingsCard {
                CardHeading(title: localized("app_language"), icon: "globe")

                Picker(localized("app_language"), selection: $localizationManager.appLanguage) {
                    Text(localized("english")).tag("en")
                    Text(localized("swedish")).tag("sv")
                    Text(localized("norwegian")).tag("no")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                // Hug the menu so it lines up with the heading above it
                .fixedSize()
                .onChange(of: localizationManager.appLanguage) { _, _ in
                    localizationManager.updateLanguage()
                }

                CardNote(localized("app_language_description"))
            }
        }
    }
}

// MARK: - Local transcription models

/// Every local transcription model, grouped as in the toolbar picker, with
/// its download state: download, cancel a running download, or delete.
struct LocalModelsView: View {
    /// Shown by the settings window, so a failure is reported even after
    /// this pane has been left.
    @Binding var downloadError: String?

    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel: String = "kb_whisper-small-coreml"
    @AppStorage("localOnlyMode") private var localOnlyMode = false
    @State private var modelToDelete: String?

    /// Same families, in the same order, as the toolbar's model picker.
    private var groups: [(title: String, modelIds: [String])] {
        [
            (localized("model_group_fast_live"), ModelManager.parakeetModels),
            ("KB Whisper", ModelManager.kbModels),
            ("NB Whisper", ModelManager.nbModels),
            ("Whisper", ModelManager.openAIModels),
        ]
    }

    /// Sum of the sizes ModelManager lists for the downloaded models.
    private var diskUsage: String {
        let bytes = modelManager.downloadedModels.reduce(Int64(0)) { total, modelId in
            total + (modelManager.modelSizeBytes(for: modelId) ?? 0)
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "0 KB" rather than "Zero KB" when nothing is downloaded
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    var body: some View {
        SettingsPane(icon: "internaldrive", title: localized("local_models")) {
            SettingsCard {
                CardHeading(title: localized("downloaded_models"), icon: "checkmark.circle.fill")
                CardNote(localized("downloaded_models_description"))
                Text(String(format: localized("models_disk_usage"), diskUsage))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
            }

            if localOnlyMode {
                SettingsCard {
                    CardHeading(title: localized("local_only_mode"), icon: "lock.shield")
                    CardNote(localized("local_only_mode_description"))
                }
            }

            ForEach(groups, id: \.title) { group in
                SettingsCard {
                    Text(group.title)
                        .font(.headline)
                        .foregroundStyle(Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    VStack(spacing: 8) {
                        ForEach(group.modelIds, id: \.self) { modelId in
                            LocalModelRow(
                                modelId: modelId,
                                isSelected: selectedModel == modelId,
                                downloadsDisabled: localOnlyMode,
                                onDownload: { download(modelId) },
                                onCancelDownload: { LocalModels.cancelDownload(modelId: modelId) },
                                onDelete: { modelToDelete = modelId }
                            )
                        }
                    }
                }
            }
        }
        .alert(localized("delete_model"), isPresented: Binding(
            get: { modelToDelete != nil },
            set: { if !$0 { modelToDelete = nil } }
        )) {
            Button(localized("remove"), role: .destructive) {
                if let modelId = modelToDelete {
                    delete(modelId)
                }
                modelToDelete = nil
            }
            Button(localized("cancel"), role: .cancel) {
                modelToDelete = nil
            }
        } message: {
            if let modelId = modelToDelete {
                Text("\(modelManager.displayName(for: modelId)) (\(modelManager.getModelSizeString(modelId)))\n\n\(localized("delete_model_confirm"))")
            }
        }
    }

    private func download(_ modelId: String) {
        let errorBinding = $downloadError
        let name = modelManager.displayName(for: modelId)
        Task {
            do {
                try await LocalModels.download(modelId: modelId)
            } catch is CancellationError {
                // The user cancelled: nothing to report
            } catch let error as URLError where error.code == .cancelled {
                // How a cancelled transfer surfaces from URLSession
            } catch {
                errorBinding.wrappedValue = "\(name): \(error.localizedDescription)"
            }
        }
    }

    private func delete(_ modelId: String) {
        let wasSelected = selectedModel == modelId
        let isLoaded = WhisperKitService.shared.currentModel == modelId
            || ParakeetService.shared.currentModel == modelId
        // A loaded model is mapped from the files about to be removed. The
        // selected model may also be mid-load, which `currentModel` can't show.
        if wasSelected || isLoaded {
            LocalModels.unloadAll()
        }

        modelManager.deleteModel(modelId)

        guard wasSelected else {
            // Reload the selection if it was unloaded along with the deleted model
            if isLoaded { LocalModels.prewarmSelectedModel() }
            return
        }
        // Same family first, as the main window does when it repairs a
        // selection. With nothing left the selection is cleared: a model that
        // stays selected without its files would be downloaded again, unasked,
        // by the next transcription.
        let engine = ModelManager.engine(for: modelId)
        let remaining = ModelManager.allLocalModels.filter { modelManager.isModelDownloaded($0) }
        selectedModel = remaining.first { ModelManager.engine(for: $0) == engine } ?? remaining.first ?? ""
        LocalModels.prewarmSelectedModel()
    }
}

private struct LocalModelRow: View {
    let modelId: String
    let isSelected: Bool
    let downloadsDisabled: Bool
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var modelManager = ModelManager.shared

    private var isDownloaded: Bool { modelManager.isModelDownloaded(modelId) }
    private var isDownloading: Bool { modelManager.isDownloading[modelId] == true }
    private var progress: Double { modelManager.downloadProgress[modelId] ?? 0 }

    /// Size, plus what sets the Parakeet-family models apart.
    private var detail: String {
        let size = modelManager.getModelSizeString(modelId)
        switch modelId {
        case "pianissimo_sv-coreml": return "\(size) · \(localized("model_desc_pianissimo"))"
        case "parakeet_tdt-v3-coreml": return "\(size) · \(localized("model_desc_parakeet"))"
        default: return size
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ContentView.icon(for: modelId))
                .foregroundStyle(isDownloaded ? Color.primaryAccent : Color.textTertiary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text(modelManager.displayName(for: modelId))
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.textPrimary)
                    if isSelected {
                        StatusBadge(text: localized("selected"))
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer(minLength: 12)

            if isDownloading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.primaryAccent)
                    .frame(width: 140)
                    .accessibilityLabel(String(format: localized("downloading_model"), modelManager.displayName(for: modelId)))
                Text("\(Int(progress * 100)) %")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.primaryAccent)
                    .frame(width: 40, alignment: .trailing)
                Button(action: onCancelDownload) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
                .help(localized("cancel_download"))
                .accessibilityLabel(localized("cancel_download"))
            } else if isDownloaded {
                Button(role: .destructive, action: onDelete) {
                    Label(localized("remove"), systemImage: "trash")
                }
                .glassAction()
                .help(localized("delete_model"))
            } else {
                Button(action: onDownload) {
                    Label(localized("download"), systemImage: "arrow.down.circle")
                }
                .glassAction()
                .disabled(downloadsDisabled)
            }
        }
        .settingsRow()
    }
}

// MARK: - Cloud transcription models

struct CloudModelsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var catalog = BergetModelCatalog.shared
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @AppStorage("localOnlyMode") private var localOnlyMode = false
    @State private var isRefreshing = false

    var body: some View {
        SettingsPane(icon: "cloud", title: localized("cloud_models")) {
            SettingsCard {
                HStack(spacing: 10) {
                    CardHeading(title: "Berget", icon: "cloud")
                    Circle()
                        .fill(settingsManager.bergetKey.isEmpty ? Color.orange : Color.primaryAccent)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                CardNote(localized("cloud_transcription_description"))

                Divider()

                if settingsManager.bergetKey.isEmpty {
                    Label(localized("api_key_required"), systemImage: "key")
                        .font(.callout)
                        .foregroundStyle(Color.orange)
                } else if catalog.asrModels.isEmpty {
                    CatalogPlaceholder(isRefreshing: isRefreshing)
                } else {
                    VStack(spacing: 8) {
                        ForEach(catalog.asrModels) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ModelManager.shared.displayName(for: "berget:\(model.id)"))
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Color.textPrimary)
                                    Text(model.id)
                                        .font(.caption)
                                        .foregroundStyle(Color.textSecondary)
                                }
                                Spacer()
                                StatusBadge(text: localized("available"))
                            }
                            .settingsRow()
                        }
                    }
                }
            }
        }
        // The catalog is otherwise fetched only at launch, so a key added
        // since then would show "unavailable" here until the next start.
        .task(id: settingsManager.bergetKey) {
            guard !localOnlyMode else { return }
            isRefreshing = true
            await catalog.refresh(apiKey: settingsManager.bergetKey)
            isRefreshing = false
        }
    }
}

/// Stands in for a model list that is empty: loading, or really unavailable.
private struct CatalogPlaceholder: View {
    let isRefreshing: Bool

    var body: some View {
        if isRefreshing {
            AccentSpinner(size: 16, lineWidth: 2)
        } else {
            Text(localized("berget_models_unavailable"))
                .font(.callout)
                .foregroundStyle(Color.textTertiary)
        }
    }
}

// MARK: - API keys

struct APIKeysView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @AppStorage("localOnlyMode") private var localOnlyMode = false
    @State private var tempBergetKey = ""
    @State private var showBergetKey = false
    @State private var bergetKeySaveFailed = false

    /// Keys are pasted, and a stray space or newline makes every request fail.
    private var trimmedBergetKey: String {
        tempBergetKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsPane(icon: "key", title: localized("api_keys")) {
            // Berget
            SettingsCard {
                CardHeading(title: "Berget 🇸🇪", icon: "mountain.2")
                CardNote(localized("berget_cloud_service_description"))

                HStack {
                    Group {
                        if showBergetKey {
                            TextField(localized("api_key"), text: $tempBergetKey)
                        } else {
                            SecureField(localized("api_key"), text: $tempBergetKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 400)

                    Button {
                        showBergetKey.toggle()
                    } label: {
                        Label(
                            localized(showBergetKey ? "hide_api_key" : "show_api_key"),
                            systemImage: showBergetKey ? "eye.slash" : "eye"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .glassAction()
                    .help(localized(showBergetKey ? "hide_api_key" : "show_api_key"))
                    .accessibilityLabel(localized(showBergetKey ? "hide_api_key" : "show_api_key"))

                    Button(localized("save"), action: saveBergetKey)
                        .glassAction()
                        .disabled(trimmedBergetKey.isEmpty)

                    if !settingsManager.bergetKey.isEmpty {
                        Button(localized("remove"), role: .destructive) {
                            if settingsManager.saveAPIKey("", for: .berget) {
                                tempBergetKey = ""
                                bergetKeySaveFailed = false
                            } else {
                                bergetKeySaveFailed = true
                            }
                        }
                        .glassAction()
                    }
                }

                if bergetKeySaveFailed {
                    Label(localized("keychain_write_failed"), systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(Color.recordingRed)
                }

                Link(localized("get_api_key_berget"), destination: URL(string: "https://berget.ai")!)
                    .font(.callout)
                    .foregroundStyle(Color.primaryAccent)
                    .pointerStyle(.link)
            }

            // Ollama
            SettingsCard {
                CardHeading(title: "Ollama", icon: "server.rack")
                CardNote(localized("ollama_description"))
                OllamaHostRow()

                if !settingsManager.ollamaModels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localized("available_models"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.textSecondary)

                        ForEach(settingsManager.ollamaModels, id: \.self) { model in
                            Label {
                                Text(model)
                                    .font(.callout)
                                    .foregroundStyle(Color.textPrimary)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(Color.primaryAccent)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            tempBergetKey = settingsManager.bergetKey
        }
    }

    private func saveBergetKey() {
        let key = trimmedBergetKey
        guard !key.isEmpty else { return }
        guard settingsManager.saveAPIKey(key, for: .berget) else {
            bergetKeySaveFailed = true
            return
        }
        bergetKeySaveFailed = false
        tempBergetKey = key

        // The catalog is otherwise fetched only at launch: with a first key
        // the model lists would say "unavailable" until the app restarts.
        guard !localOnlyMode else { return }
        Task {
            await BergetModelCatalog.shared.refresh(apiKey: key)
        }
    }
}

// MARK: - Ollama connection

/// What a probe of the Ollama server found. Views read this state — never
/// a status string — for both their wording and their logic.
@MainActor
final class OllamaConnection: ObservableObject {
    enum State: Equatable {
        /// Not checked yet.
        case unknown
        case checking
        /// Reachable, with at least one model installed.
        case connected
        /// Reachable, but no models are installed.
        case noModels
        /// The host setting is not an http(s) URL.
        case invalidURL
        /// Something answered, but not the way Ollama does.
        case failed
        /// Nothing is listening at the host.
        case notRunning
        /// Local-only mode is on and the host is another computer, so it is
        /// not contacted at all.
        case blockedByLocalOnly
    }

    @Published private(set) var state: State = .unknown

    /// Only the newest check may publish its result.
    private var latestCheck = 0

    /// Asks the server at `host` for its installed models and publishes them
    /// through `settings`, where the rest of the app reads them.
    func check(host: String, settings: SettingsManager) async {
        latestCheck += 1
        let check = latestCheck
        state = .checking

        func finish(_ newState: State, models: [String] = []) {
            guard check == latestCheck else { return }
            settings.ollamaModels = models
            state = newState
        }

        guard let url = URL(string: "\(host)/api/tags"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            finish(.invalidURL)
            return
        }
        // Local-only mode: nothing goes to another computer, not even a probe
        if settings.localOnlyMode, !LLMService.isOnThisComputer(host) {
            finish(.blockedByLocalOnly)
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                finish(.failed)
                return
            }
            let names = models.compactMap { $0["name"] as? String }
            finish(names.isEmpty ? .noModels : .connected, models: names)
        } catch {
            // The pane that asked went away: there is no answer to report
            guard !Task.isCancelled else {
                if check == latestCheck { state = .unknown }
                return
            }
            finish(.notRunning)
        }
    }
}

/// Host field, "Test connection" and the result, shared by the two panes
/// that deal with Ollama.
private struct OllamaHostRow: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var ollama: OllamaConnection
    
    var body: some View {
        HStack {
            TextField(localized("host_url"), text: $settingsManager.ollamaHost)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 400)
                .accessibilityLabel(localized("host_url"))

            Button(localized("test_connection"), action: check)
                .glassAction()
                .disabled(ollama.state == .checking)
        }

        status
    }

    @ViewBuilder
    private var status: some View {
        switch ollama.state {
        case .unknown:
            EmptyView()
        case .checking:
            StatusBadge(text: localized("ollama_connecting"), color: .textTertiary)
        case .connected:
            StatusBadge(text: localized("ollama_connected"))
        case .noModels:
            StatusBadge(text: localized("ollama_connected_no_models"), color: .orange)
        case .invalidURL:
            StatusBadge(text: localized("ollama_invalid_url"), color: .orange)
        case .failed:
            StatusBadge(text: localized("ollama_connection_failed"), color: .orange)
        case .blockedByLocalOnly:
            StatusBadge(text: localized("ollama_blocked_local_only"), color: .orange)
        case .notRunning:
            HStack(spacing: 4) {
                StatusBadge(text: localized("ollama_not_installed"), color: .orange)
                Link("ollama.com", destination: URL(string: "https://ollama.com")!)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primaryAccent)
                    .pointerStyle(.link)
            }
        }
    }

    private func check() {
        Task {
            await ollama.check(host: settingsManager.ollamaHost, settings: settingsManager)
        }
    }
}

// MARK: - Local language models

struct LLMLocalModelsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var ollama: OllamaConnection
    @ObservedObject private var localizationManager = LocalizationManager.shared

    var body: some View {
        SettingsPane(icon: "laptopcomputer", title: localized("local_models")) {
            SettingsCard {
                CardHeading(title: "Ollama", icon: "laptopcomputer")
                CardNote(localized("ollama_llm_description"))

                Divider()

                OllamaHostRow()

                if !settingsManager.ollamaModels.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(settingsManager.ollamaModels, id: \.self) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Color.textPrimary)
                                    Text(localized("local_language_model"))
                                        .font(.caption)
                                        .foregroundStyle(Color.textSecondary)
                                }
                                Spacer()
                                StatusBadge(text: localized("available"))
                            }
                            .settingsRow()
                        }
                    }
                }
            }
        }
        .task {
            await ollama.check(host: settingsManager.ollamaHost, settings: settingsManager)
        }
    }
}

// MARK: - Cloud language models

struct LLMCloudModelsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var catalog = BergetModelCatalog.shared
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @AppStorage("localOnlyMode") private var localOnlyMode = false
    @State private var isRefreshing = false

    var body: some View {
        SettingsPane(icon: "cloud", title: localized("cloud_models")) {
            // Berget Models (GDPR safe)
            SettingsCard {
                HStack(spacing: 10) {
                    CardHeading(title: "Berget AI", icon: "cloud")
                    Circle()
                        .fill(settingsManager.bergetKey.isEmpty ? Color.textTertiary : Color.primaryAccent)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                CardNote(localized("berget_llm_description"))

                if settingsManager.bergetKey.isEmpty {
                    Label(localized("api_key_required"), systemImage: "key")
                        .font(.callout)
                        .foregroundStyle(Color.orange)
                }

                Divider()

                if catalog.llmModels.isEmpty {
                    CatalogPlaceholder(isRefreshing: isRefreshing)
                } else {
                    VStack(spacing: 8) {
                        ForEach(catalog.llmModels) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(Color.textPrimary)
                                        if !model.isStable {
                                            Text(model.lifecycleState)
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.2), in: Capsule())
                                                .foregroundStyle(Color.orange)
                                        }
                                    }
                                    Text(model.id)
                                        .font(.caption)
                                        .foregroundStyle(Color.textSecondary)
                                }
                                Spacer()
                                Circle()
                                    .fill(settingsManager.bergetKey.isEmpty ? Color.textTertiary.opacity(0.5) : Color.primaryAccent)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                            .settingsRow()
                        }
                    }
                }
            }
        }
        .task(id: settingsManager.bergetKey) {
            guard !localOnlyMode else { return }
            isRefreshing = true
            await catalog.refresh(apiKey: settingsManager.bergetKey)
            isRefreshing = false
        }
    }
}

// MARK: - Text processing prompts

/// Unsaved prompt edits. Every prompt keeps its own draft, so opening one
/// editor never discards what was typed in another.
struct PromptDrafts {
    struct Draft {
        var name: String
        var prompt: String

        var trimmedName: String {
            name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// A name or a prompt of nothing but whitespace is as good as empty.
        var canBeSaved: Bool {
            !trimmedName.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Open editors of existing prompts, by prompt id.
    var edits: [UUID: Draft] = [:]
    /// The "add prompt" editor, while it is open.
    var new: Draft?
}

struct TextProcessingPromptsView: View {
    @Binding var drafts: PromptDrafts

    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @State private var promptToDelete: TextProcessingPrompt?

    var body: some View {
        SettingsPane(icon: "text.bubble", title: localized("process_text")) {
            SettingsCard {
                CardHeading(title: localized("prompts"), icon: "list.bullet.rectangle")
                CardNote(localized("prompts_settings_description"))

                Divider()

                // Prompt list
                VStack(spacing: 8) {
                    ForEach(settingsManager.textProcessingPrompts) { prompt in
                        promptRow(for: prompt)
                    }
                }

                // Add button
                if drafts.new != nil {
                    PromptEditor(
                        draft: Binding(
                            get: { drafts.new ?? PromptDrafts.Draft(name: "", prompt: "") },
                            set: { drafts.new = $0 }
                        ),
                        onCancel: { drafts.new = nil },
                        onSave: { draft in
                            settingsManager.addPrompt(TextProcessingPrompt(name: draft.trimmedName, prompt: draft.prompt))
                            drafts.new = nil
                        }
                    )
                    .settingsRow()
                } else {
                    Button {
                        drafts.new = PromptDrafts.Draft(name: "", prompt: "")
                    } label: {
                        Label(localized("add_prompt"), systemImage: "plus")
                    }
                    .glassAction()
                }
            }
        }
        .alert(localized("delete_prompt"), isPresented: Binding(
            get: { promptToDelete != nil },
            set: { if !$0 { promptToDelete = nil } }
        )) {
            Button(localized("remove"), role: .destructive) {
                if let prompt = promptToDelete {
                    drafts.edits[prompt.id] = nil
                    settingsManager.deletePrompt(prompt)
                }
                promptToDelete = nil
            }
            Button(localized("cancel"), role: .cancel) {
                promptToDelete = nil
            }
        } message: {
            if let prompt = promptToDelete {
                Text(prompt.name)
            }
        }
    }
    
    // MARK: - Prompt Row
    
    @ViewBuilder
    private func promptRow(for prompt: TextProcessingPrompt) -> some View {
        if drafts.edits[prompt.id] != nil {
            PromptEditor(
                draft: Binding(
                    get: { drafts.edits[prompt.id] ?? PromptDrafts.Draft(name: prompt.name, prompt: prompt.prompt) },
                    set: { drafts.edits[prompt.id] = $0 }
                ),
                onCancel: { drafts.edits[prompt.id] = nil },
                onSave: { draft in
                    var updated = prompt
                    updated.name = draft.trimmedName
                    updated.prompt = draft.prompt
                    settingsManager.updatePrompt(updated)
                    drafts.edits[prompt.id] = nil
                }
            )
            .settingsRow()
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.textPrimary)
                    Text(prompt.prompt)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                Button {
                    // Opens next to any editor that is already open
                    drafts.edits[prompt.id] = PromptDrafts.Draft(name: prompt.name, prompt: prompt.prompt)
                } label: {
                    Label(localized("edit_prompt"), systemImage: "pencil")
                }
                .labelStyle(.iconOnly)
                .glassAction()
                .help(localized("edit_prompt"))
                .accessibilityLabel(localized("edit_prompt"))

                Button(role: .destructive) {
                    promptToDelete = prompt
                } label: {
                    Label(localized("delete_prompt"), systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .glassAction()
                .help(localized("delete_prompt"))
                .accessibilityLabel(localized("delete_prompt"))
            }
            .settingsRow()
        }
    }
}

/// Name and text fields for one prompt, new or existing.
private struct PromptEditor: View {
    @Binding var draft: PromptDrafts.Draft
    let onCancel: () -> Void
    let onSave: (PromptDrafts.Draft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(localized("prompt_name"), text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(localized("prompt_name"))

            TextEditor(text: $draft.prompt)
                .font(.body)
                // Without this the editor paints its own background over ours
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(6)
                .background(Color.surfaceBackground, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .strokeBorder(Color.borderLight, lineWidth: 0.5)
                )
                .accessibilityLabel(localized("ios_llm_prompt_label"))

            HStack {
                Spacer()
                Button(localized("cancel"), action: onCancel)
                    .glassAction()
                Button(localized("save")) {
                    onSave(draft)
                }
                .glassAction()
                .disabled(!draft.canBeSaved)
            }
        }
    }
}

// MARK: - Shared pieces

/// The frame every pane shares: a large rounded title, then its cards.
private struct SettingsPane<Content: View>: View {
    let icon: String
    let title: String
    let content: Content

    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Label {
                Text(title)
                    .foregroundStyle(Color.textPrimary)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(Color.primaryAccent)
            }
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 4)

            content
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }
}

/// The icon and title that head a card.
private struct CardHeading: View {
    let title: String
    let icon: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(Color.textPrimary)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Color.primaryAccent)
        }
        .font(.headline)
    }
}

/// Explanatory text under a card's heading.
private struct CardNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// An inset row inside a card.
    func settingsRow() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.elevatedSurface, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsManager())
}
