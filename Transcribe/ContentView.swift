import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var bergetCatalog = BergetModelCatalog.shared
    @AppStorage("selectedTranscriptionModel") private var selectedModel: String = "kb_whisper-small-coreml"
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var isDraggingFile = false
    @State private var showModelPopover = false
    @State private var showFileImporter = false
    @State private var showYouTubeView = false
    @State private var showFileError = false
    @State private var fileErrorMessage = ""
    @State private var showModelDownloadError = false
    @State private var modelDownloadErrorMessage = ""
    /// A model the user picked that is still downloading; it becomes the
    /// selection only if its download succeeds.
    @State private var modelAwaitingDownload: String?

    private static let defaultModelId = "kb_whisper-small-coreml"

    var body: some View {
        ZStack {
            // The brand wash is strongest on the home screen and recedes
            // behind working screens so it never competes with content.
            AuroraBackdrop(intensity: appState.isHome ? 1 : 0.4)
            screen
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(removing: .title)
        .toolbar(removing: .sidebarToggle)
        // No bar behind the toolbar: its items are glass and float over the
        // content, which runs to the top edge of the window.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarSpacer(.flexible)

            ToolbarItem {
                languageMenu
            }
            ToolbarItem {
                modelPicker
            }

            ToolbarSpacer(.fixed)

            ToolbarItem {
                themeToggle
            }
            ToolbarItem {
                SettingsLink {
                    Label(localized("settings"), systemImage: "gearshape")
                }
                .help(localized("settings"))
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Sandboxed app: keep access to the user-selected file while it's open
                    appState.openFileForTranscription(url, isSecurityScoped: true)
                }
            case .failure(let error):
                fileErrorMessage = error.localizedDescription
                showFileError = true
            }
        }
        .alert(localized("file_open_error"), isPresented: $showFileError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(fileErrorMessage)
        }
        .alert(localized("model_download_failed_title"), isPresented: $showModelDownloadError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(modelDownloadErrorMessage)
        }
        .alert(localized("leave_recording"), isPresented: pendingNavigationBinding) {
            Button(localized("stay"), role: .cancel) {
                appState.cancelPendingNavigation()
            }
            Button(localized("leave"), role: .destructive) {
                appState.confirmPendingNavigation()
            }
        } message: {
            Text(unsavedWorkMessage)
        }
        .sheet(isPresented: $showYouTubeView) {
            YouTubeTranscriptionView()
        }
        // While a recording exists only in this window, closing the window
        // would discard it without a word.
        .windowDismissBehavior(holdsRecording ? .disabled : .enabled)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowTranscriptionView"))) { notification in
            if let fileURL = notification.userInfo?["fileURL"] as? URL {
                appState.openFileForTranscription(fileURL)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenFile)) { _ in
            showFileImporter = true
        }
        .onAppear {
            SceneActions.shared.openMainWindow = { openWindow(id: SceneID.main) }
            SceneActions.shared.openSettings = { openSettings() }
            #if DEBUG
            DebugHarness.runLaunchHooks(appState: appState)
            if UserDefaults.standard.bool(forKey: "debugShowModelPicker") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showModelPopover = true }
            }
            if UserDefaults.standard.string(forKey: "debugSettingsSection") != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openSettings() }
            }
            if UserDefaults.standard.bool(forKey: "debugShowYouTube") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showYouTubeView = true }
            }
            #endif
        }
        .onDisappear {
            appState.mainWindowDidClose()
        }
        .onChange(of: settingsManager.localOnlyMode) { _, _ in repairModelSelection() }
        .onChange(of: settingsManager.bergetKey) { _, _ in repairModelSelection() }
        .onChange(of: modelManager.downloadedModels) { _, _ in repairModelSelection() }
        .task {
            await launchTasks()
        }
    }

    // MARK: - Screens

    @ViewBuilder
    private var screen: some View {
        switch appState.screen {
        case .home:
            homeScreen
        case .recording:
            RecordingView()
        case .systemAudio:
            SystemAudioRecordingView()
        case .transcription(let url):
            TranscriptionView(fileURL: url)
                .id(url)
        }
    }

    private var holdsRecording: Bool {
        appState.unsavedWork == .recordingInProgress || appState.unsavedWork == .untranscribedRecording
    }

    private var pendingNavigationBinding: Binding<Bool> {
        Binding(
            get: { appState.pendingNavigation != nil },
            set: { if !$0 { appState.cancelPendingNavigation() } }
        )
    }

    private var unsavedWorkMessage: String {
        switch appState.unsavedWork {
        case .recordingInProgress: return localized("recording_in_progress_leave")
        case .untranscribedRecording: return localized("untranscribed_recording_leave")
        case .unsavedTranscript, .none: return localized("unsaved_transcript_leave")
        }
    }

    // MARK: - Home

    private var homeScreen: some View {
        ZStack {
            if isDraggingFile {
                dropOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    hero
                    Spacer(minLength: 24)
                    footer
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 26)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Drops are only meaningful here; on other screens a dropped file
        // would silently replace the work in progress.
        .onDrop(of: [.fileURL], isTargeted: $isDraggingFile) { providers in
            handleFileDrop(providers)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isDraggingFile)
    }

    private var hero: some View {
        VStack(spacing: 36) {
            VStack(spacing: 14) {
                Text(localized("transcribe"))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient.accentGradient)
                Text(localized("drag_drop_hint"))
                    .font(.title3)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

            GlassEffectContainer(spacing: 20) {
                HStack(spacing: 20) {
                    FeatureTile(icon: "doc.badge.arrow.up", title: localized("open_files"), subtitle: localized("tile_files_sub")) {
                        showFileImporter = true
                    }
                    FeatureTile(icon: "mic", title: localized("new_recording"), subtitle: localized("tile_record_sub")) {
                        appState.navigate(to: .recording)
                    }
                    FeatureTile(icon: "speaker.wave.2", title: localized("system_audio"), subtitle: localized("tile_system_sub")) {
                        appState.navigate(to: .systemAudio)
                    }
                    if !settingsManager.localOnlyMode {
                        FeatureTile(icon: "play.rectangle", title: "YouTube", subtitle: localized("tile_youtube_sub")) {
                            showYouTubeView = true
                        }
                    }
                }
            }

            if let notice = languageMismatchNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentCard(cornerRadius: Metrics.controlRadius)
                    .transition(.opacity)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text(localized("footer_credit"))
                .foregroundStyle(Color.textTertiary)
            HStack(spacing: 10) {
                Button(localized("help_support")) {
                    if let url = URL(string: "https://github.com/mickekring/Transcribe-MacOS-App") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primaryAccent)
                .pointerStyle(.link)

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("·").foregroundStyle(Color.textTertiary)
                    Text(String(format: localized("version_format"), version, build))
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
        .font(.caption)
    }

    private var dropOverlay: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.primaryAccent)
                .frame(width: 104, height: 104)
                .background(Color.primaryAccent.opacity(0.14), in: Circle())
            VStack(spacing: 6) {
                Text(localized("drop_files_here"))
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(localized("drop_release_hint"))
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primaryAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
        )
        .padding(36)
    }

    /// Explains why the chosen model can't transcribe the chosen language,
    /// before the user finds out from a wrong transcript.
    private var languageMismatchNotice: String? {
        let language = languageManager.selectedLanguage
        guard !ModelManager.supports(languageCode: language.code, modelId: selectedModel) else { return nil }
        return String(format: localized("language_model_mismatch"), modelManager.displayName(for: selectedModel), language.localizedName)
    }

    // MARK: - Toolbar items

    private var themeToggle: some View {
        Button {
            appColorScheme = appColorScheme == "dark" ? "light" : "dark"
        } label: {
            Label(
                appColorScheme == "dark" ? localized("switch_to_light") : localized("switch_to_dark"),
                systemImage: appColorScheme == "dark" ? "moon" : "sun.max"
            )
        }
        .help(appColorScheme == "dark" ? localized("switch_to_light") : localized("switch_to_dark"))
    }

    private var languageMenu: some View {
        Menu {
            Picker(localized("language"), selection: languageSelection) {
                ForEach(TranscriptionLanguage.commonLanguages) { language in
                    Text(menuTitle(for: language)).tag(language.code)
                }
            }
            .pickerStyle(.inline)

            Picker(localized("more_languages"), selection: languageSelection) {
                ForEach(TranscriptionLanguage.allLanguages.filter { language in
                    !TranscriptionLanguage.commonLanguages.contains { $0.id == language.id }
                }) { language in
                    Text(menuTitle(for: language)).tag(language.code)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ToolbarChooserLabel(title: languageManager.selectedLanguage.localizedName) {
                Image(systemName: "globe")
            }
        }
        // The label draws its own chevron, the same one the model picker has
        .menuIndicator(.hidden)
        .help(localized("language"))
        .accessibilityLabel("\(localized("language")): \(languageManager.selectedLanguage.localizedName)")
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { languageManager.selectedLanguage.code },
            set: { code in
                if let language = TranscriptionLanguage.allLanguages.first(where: { $0.code == code }) {
                    languageManager.selectLanguage(language)
                }
            }
        )
    }

    private func menuTitle(for language: TranscriptionLanguage) -> String {
        language.code == "auto" ? language.localizedName : "\(Self.flag(for: language.code))  \(language.localizedName)"
    }

    private var activeDownload: (modelId: String, progress: Double)? {
        guard let id = modelManager.isDownloading.first(where: { $0.value })?.key else { return nil }
        return (id, modelManager.downloadProgress[id] ?? 0)
    }

    private var modelButtonTitle: String {
        if let download = activeDownload {
            return "\(modelManager.displayName(for: download.modelId)) \(Int(download.progress * 100)) %"
        }
        return selectedModel.isEmpty ? localized("select_model") : modelManager.displayName(for: selectedModel)
    }

    private var modelPicker: some View {
        Button {
            showModelPopover.toggle()
        } label: {
            ToolbarChooserLabel(title: modelButtonTitle) {
                if activeDownload != nil {
                    Image(systemName: "arrow.down.circle")
                        .symbolEffect(.pulse)
                } else {
                    Image(systemName: Self.icon(for: selectedModel))
                }
            }
            .monospacedDigit()
        }
        .help(localized("model"))
        .accessibilityLabel("\(localized("model")): \(modelManager.displayName(for: selectedModel))")
        .popover(isPresented: $showModelPopover, arrowEdge: .bottom) {
            ModelPickerList(
                selectedModel: selectedModel,
                awaitingDownload: modelAwaitingDownload,
                showCloud: !settingsManager.bergetKey.isEmpty && !settingsManager.localOnlyMode,
                cloudModelIds: bergetCatalog.asrModels.isEmpty
                    ? ["berget:KBLab/kb-whisper-large"]   // catalog not fetched yet: legacy default
                    : bergetCatalog.asrModels.map { "berget:\($0.id)" },
                onSelect: { modelId in
                    choose(modelId)
                },
                onCancelDownload: { modelId in
                    if modelAwaitingDownload == modelId { modelAwaitingDownload = nil }
                    LocalModels.cancelDownload(modelId: modelId)
                }
            )
        }
    }

    // MARK: - Model selection

    private func choose(_ modelId: String) {
        let isLocal = ModelManager.engine(for: modelId) != .cloud
        if !isLocal || modelManager.isModelDownloaded(modelId) {
            selectedModel = modelId
            modelAwaitingDownload = nil
            showModelPopover = false
            LocalModels.prewarmSelectedModel()
            return
        }
        // Not on disk yet: download first and switch only when it is usable,
        // so a cancelled or failed download never leaves a model selected
        // that would silently start downloading again at the next transcription.
        modelAwaitingDownload = modelId
        guard modelManager.isDownloading[modelId] != true else { return }
        Task {
            await downloadModel(modelId)
            if modelAwaitingDownload == modelId {
                modelAwaitingDownload = nil
                if modelManager.isModelDownloaded(modelId) {
                    selectedModel = modelId
                    LocalModels.prewarmSelectedModel()
                }
            }
        }
    }

    private func downloadModel(_ modelId: String) async {
        do {
            try await LocalModels.download(modelId: modelId)
        } catch is CancellationError {
            // User cancelled from the picker — no error alert
        } catch {
            modelDownloadErrorMessage = "\(modelManager.displayName(for: modelId)): \(error.localizedDescription)\n\n\(localized("model_download_retry_hint"))"
            showModelDownloadError = true
        }
    }

    /// Keeps the selection pointing at something that can actually run: a
    /// cloud model needs a key and network permission, a local model must be
    /// on disk (or on its way).
    private func repairModelSelection() {
        let engine = ModelManager.engine(for: selectedModel)
        let usable: Bool
        switch engine {
        case .cloud:
            usable = !settingsManager.localOnlyMode && !settingsManager.bergetKey.isEmpty
        case .whisperKit, .parakeet:
            usable = modelManager.isModelDownloaded(selectedModel) || modelManager.isDownloading[selectedModel] == true
        case .none:
            usable = false
        }
        guard !usable else { return }
        // Prefer staying in the same family, then anything downloaded
        let downloaded = ModelManager.allLocalModels.filter { modelManager.isModelDownloaded($0) }
        if let replacement = downloaded.first(where: { ModelManager.engine(for: $0) == engine }) ?? downloaded.first {
            selectedModel = replacement
        }
    }

    private func launchTasks() async {
        // Legacy cloud id
        if selectedModel == "berget-kb-whisper-large" {
            selectedModel = "berget:KBLab/kb-whisper-large"
        }

        // First launch only: fetch the default model. Never on later
        // launches — a user who works with cloud models, or who is in
        // local-only mode, must not have a selection overwritten or a
        // download started behind their back.
        let isFirstLaunch = UserDefaults.standard.object(forKey: "selectedTranscriptionModel") == nil
        if isFirstLaunch, modelManager.downloadedModels.isEmpty, !settingsManager.localOnlyMode {
            selectedModel = Self.defaultModelId
            Task { await downloadModel(Self.defaultModelId) }
        } else {
            repairModelSelection()
        }

        // Load the selected model in the background so the first
        // transcription doesn't pay the (potentially long) ANE load.
        LocalModels.prewarmSelectedModel()

        if !settingsManager.localOnlyMode {
            await bergetCatalog.refresh(apiKey: settingsManager.bergetKey)
        }
    }

    // MARK: - File drop

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                isDraggingFile = false
                guard let url, Self.isTranscribable(url) else {
                    fileErrorMessage = localized("unsupported_file_type")
                    showFileError = true
                    return
                }
                appState.openFileForTranscription(url)
            }
        }
        return true
    }

    /// Same rule as the open panel: anything the system types as audio or a movie.
    static func isTranscribable(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    // MARK: - Lookups

    static func icon(for modelId: String) -> String {
        // Where it runs, not which engine: every local model is a computer
        switch ModelManager.engine(for: modelId) {
        case .whisperKit, .parakeet: return "laptopcomputer"
        case .cloud: return "cloud"
        case .none: return "cube"
        }
    }

    static func flag(for code: String) -> String {
        switch code {
        case "sv": return "🇸🇪"
        case "en": return "🇬🇧"
        case "ar": return "🇸🇦"
        case "zh": return "🇨🇳"
        case "da": return "🇩🇰"
        case "nl": return "🇳🇱"
        case "fi": return "🇫🇮"
        case "fr": return "🇫🇷"
        case "de": return "🇩🇪"
        case "hi": return "🇮🇳"
        case "it": return "🇮🇹"
        case "ja": return "🇯🇵"
        case "ko": return "🇰🇷"
        case "no": return "🇳🇴"
        case "pl": return "🇵🇱"
        case "pt": return "🇵🇹"
        case "ru": return "🇷🇺"
        case "es": return "🇪🇸"
        case "tr": return "🇹🇷"
        case "uk": return "🇺🇦"
        default: return "🌐"
        }
    }
}

// MARK: - Model picker

/// The model list shown from the toolbar: grouped by family, with download
/// state, size and progress per model.
private struct ModelPickerList: View {
    let selectedModel: String
    let awaitingDownload: String?
    let showCloud: Bool
    let cloudModelIds: [String]
    let onSelect: (String) -> Void
    let onCancelDownload: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                group(localized("model_group_fast_live"), ModelManager.parakeetModels)
                group("KB Whisper", ModelManager.kbModels)
                group("NB Whisper", ModelManager.nbModels)
                group("Whisper", ModelManager.openAIModels)
                if showCloud {
                    group(localized("cloud_models"), cloudModelIds)
                }
            }
            .padding(8)
        }
        .frame(width: 320)
        .frame(maxHeight: 520)
    }

    @ViewBuilder
    private func group(_ title: String, _ modelIds: [String]) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.textTertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 3)
        ForEach(modelIds, id: \.self) { modelId in
            ModelPickerRow(
                modelId: modelId,
                isSelected: selectedModel == modelId,
                isAwaitingDownload: awaitingDownload == modelId,
                onSelect: { onSelect(modelId) },
                onCancelDownload: { onCancelDownload(modelId) }
            )
        }
    }
}

private struct ModelPickerRow: View {
    let modelId: String
    let isSelected: Bool
    let isAwaitingDownload: Bool
    let onSelect: () -> Void
    let onCancelDownload: () -> Void

    @ObservedObject private var modelManager = ModelManager.shared
    @State private var isHovered = false

    private var isCloud: Bool { ModelManager.engine(for: modelId) == .cloud }
    private var isDownloaded: Bool { modelManager.isModelDownloaded(modelId) }
    private var isDownloading: Bool { modelManager.isDownloading[modelId] == true }
    private var progress: Double { modelManager.downloadProgress[modelId] ?? 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: ContentView.icon(for: modelId))
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.primaryAccent : Color.textSecondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(modelManager.displayName(for: modelId))
                            .font(.body)
                            .foregroundStyle(isDownloaded || isCloud ? Color.textPrimary : Color.textSecondary)
                        if isDownloading {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(.primaryAccent)
                                .frame(maxWidth: 150)
                                .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: 8)

                    if isDownloading {
                        Text("\(Int(progress * 100)) %")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.primaryAccent)
                    } else if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.primaryAccent)
                    } else if !isDownloaded && !isCloud {
                        Text(modelManager.getModelSizeString(modelId))
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isDownloading {
                Button(action: onCancelDownload) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
                .help(localized("cancel_download"))
                .accessibilityLabel(localized("cancel_download"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.hoverBackground : .clear)
        )
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isAwaitingDownload ? localized("model_selected_after_download") : "")
    }
}
