import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var localizationManager = LocalizationManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @State private var isDraggingFile = false
    @AppStorage("selectedTranscriptionModel") private var selectedModel: String = "kb_whisper-small-coreml"
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @State private var showLanguagePopover = false
    @State private var showModelPopover = false
    @State private var showFileImporter = false
    @State private var showYouTubeView = false
    private let whisperKitService = WhisperKitService()
    
    var body: some View {
        Group {
            if appState.showRecordingView {
                RecordingView()
            } else if appState.showTranscriptionView, let url = appState.currentTranscriptionURL {
                TranscriptionView(fileURL: url)
            } else {
                mainContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceBackground)
        .navigationTitle("")
        .toolbar(removing: .title)
        .toolbar(removing: .sidebarToggle)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarSpacer(.flexible)

            ToolbarItem {
                languageDropdown
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem {
                modelDropdown
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem {
                themeToggle
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem {
                settingsButton
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDraggingFile) { providers in
            handleFileDrop(providers)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .movie, .mp3, .wav, .mpeg4Audio, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    appState.openFileForTranscription(url)
                }
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showYouTubeView) {
            YouTubeTranscriptionView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowTranscriptionView"))) { notification in
            if let userInfo = notification.userInfo,
               let fileURL = userInfo["fileURL"] as? URL {
                appState.openFileForTranscription(fileURL)
            }
        }
        .task {
            // Auto-download default model on first launch if no models are downloaded
            let defaultModelId = "kb_whisper-small-coreml"
            if modelManager.downloadedModels.isEmpty && modelManager.isDownloading[defaultModelId] != true {
                selectedModel = defaultModelId
                await downloadModel(defaultModelId)
            }
        }
    }
    
    var mainContent: some View {
        ZStack {
            // Subtle green radial glow on dark surface
            Color.surfaceBackground
                .ignoresSafeArea()
            
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.primaryAccent.opacity(0.06),
                    Color.clear
                ]),
                center: .top,
                startRadius: 100,
                endRadius: 600
            )
            .ignoresSafeArea()
            
            if isDraggingFile {
                dragOverlay
            } else {
                featureGrid
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDraggingFile)
    }
    
    var featureGrid: some View {
        VStack {
            Spacer()
            
            VStack(spacing: 32) {
                VStack(spacing: 24) {
                    Text(localized("transcribe"))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient.accentGradient)
                    
                    Text(localized("drag_drop_hint"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
                
                primaryFeatures
            }
            
            Spacer()
            
            footerSection
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 30)
    }
    
    var footerSection: some View {
        VStack(spacing: 12) {
            Text(localizationManager.currentLanguage == "sv" ? "En prototyp av Micke Kring - mickekring.se" : "A prototype by Micke Kring - mickekring.se")
                .font(.system(size: 12))
                .foregroundColor(.textSecondary)
            
            Button(action: {
                if let url = URL(string: "https://github.com/mickekring/Transcribe-MacOS-App") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text(localizationManager.currentLanguage == "sv" ? "Hjälp / Support" : "Help / Support")
                    .font(.system(size: 12))
                    .foregroundColor(.primaryAccent)
                    .underline()
            }
            .buttonStyle(.plain)
            
            // Version and build number
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Version \(version) (\(build))")
                    .font(.system(size: 12))
                    .foregroundColor(.textSecondary)
            }
        }
    }
    
    var primaryFeatures: some View {
        HStack(spacing: 20) {
            FeatureCard(
                icon: "doc.badge.arrow.up.fill",
                title: "Öppna filer",
                action: openFiles
            )
            
            FeatureCard(
                icon: "mic.circle.fill",
                title: localized("new_recording"),
                action: newRecording
            )
            
            FeatureCard(
                icon: "play.rectangle.fill",
                title: "YouTube",
                action: {
                    showYouTubeView = true
                }
            )
        }
    }
    
    
    var dragOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.primaryAccent.opacity(0.4), lineWidth: 1.5)
                )
                .shadow(color: Color.primaryAccent.opacity(0.15), radius: 30, y: 10)
                .padding(40)
            
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.primaryAccent.opacity(0.15))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                
                VStack(spacing: 8) {
                    Text(localized("drop_files_here"))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(.textPrimary)
                    
                    Text("Release to start transcription")
                        .font(.system(size: 14))
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }
    
    var themeToggle: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                appColorScheme = appColorScheme == "dark" ? "light" : "dark"
            }
        }) {
            Image(systemName: appColorScheme == "dark" ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 16))
                .foregroundColor(.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.elevatedSurface)
                )
        }
        .buttonStyle(.plain)
        .help(appColorScheme == "dark" ? localized("switch_to_light") : localized("switch_to_dark"))
    }

    var settingsButton: some View {
        SettingsLink {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16))
                .foregroundColor(.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.elevatedSurface)
                )
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
    }
    
    // MARK: - Actions
    
    func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, error in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            
            // Check if it's a supported audio/video file
            let supportedExtensions = ["mp3", "wav", "m4a", "m4b", "mp4", "ogg", "aac", "mov", "flac", "opus", "webm"]
            if supportedExtensions.contains(url.pathExtension.lowercased()) {
                DispatchQueue.main.async {
                    self.isDraggingFile = false
                    self.appState.openFileForTranscription(url)
                }
            }
        }
        return true
    }
    
    func openFiles() {
        showFileImporter = true
    }
    
    func newRecording() {
        appState.showRecordingView = true
    }
    
    func downloadModel(_ modelId: String) async {
        do {
            try await whisperKitService.downloadOnly(modelId: modelId)
        } catch {
            // Model download failed
        }
    }
    
    // MARK: - Dropdown Views
    
    var languageDropdown: some View {
        Button(action: {
            showLanguagePopover.toggle()
        }) {
            HStack(spacing: 6) {
                if languageManager.selectedLanguage.code == "auto" {
                    Image(systemName: "globe")
                        .font(.system(size: 18))
                        .foregroundStyle(LinearGradient.accentGradient)
                } else {
                    Text(getLanguageFlag(languageManager.selectedLanguage.code))
                        .font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("language"))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                    Text(languageManager.selectedLanguage.localizedName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.elevatedSurface)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $showLanguagePopover) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(TranscriptionLanguage.commonLanguages) { language in
                    Button(action: {
                        languageManager.selectLanguage(language)
                        showLanguagePopover = false
                    }) {
                        HStack {
                            if language.code == "auto" {
                                Image(systemName: "globe")
                                    .font(.system(size: 16))
                                    .foregroundStyle(LinearGradient.accentGradient)
                                    .frame(width: 20)
                            } else {
                                Text(getLanguageFlag(language.code))
                                    .font(.system(size: 16))
                            }
                            Text(language.localizedName)
                                .foregroundColor(.primary)
                            Spacer()
                            if languageManager.selectedLanguage.id == language.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { isHovered in
                        if isHovered {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                
                Divider()
                    .padding(.vertical, 4)
                
                Text(localized("more_languages"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                
                ForEach(TranscriptionLanguage.allLanguages.filter { lang in
                    !TranscriptionLanguage.commonLanguages.contains(where: { $0.id == lang.id })
                }) { language in
                    Button(action: {
                        languageManager.selectLanguage(language)
                        showLanguagePopover = false
                    }) {
                        HStack {
                            Text(getLanguageFlag(language.code))
                                .font(.system(size: 16))
                            Text(language.localizedName)
                                .foregroundColor(.primary)
                            Spacer()
                            if languageManager.selectedLanguage.id == language.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { isHovered in
                        if isHovered {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(width: 200)
        }
    }
    
    var modelDropdown: some View {
        Button(action: {
            showModelPopover.toggle()
        }) {
            HStack(spacing: 6) {
                if modelManager.isDownloading.values.contains(true) {
                    AccentSpinner(size: 18, lineWidth: 2)
                } else {
                    Image(systemName: getModelIcon(selectedModel))
                        .font(.system(size: 18))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("model"))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                    Text(selectedModel.isEmpty ? localized("select_model") : modelManager.displayName(for: selectedModel))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(selectedModel.isEmpty ? .textTertiary : .textPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.elevatedSurface)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $showModelPopover) {
            VStack(alignment: .leading, spacing: 0) {
                // KB Whisper models
                Text("KB Whisper")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                
                ForEach(ModelManager.kbModels, id: \.self) { modelId in
                    modelDropdownRow(modelId: modelId, icon: "laptopcomputer")
                }
                
                Divider().padding(.horizontal, 12).padding(.vertical, 4)
                
                // OpenAI Whisper models
                Text("Whisper")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                
                ForEach(ModelManager.openAIModels, id: \.self) { modelId in
                    modelDropdownRow(modelId: modelId, icon: "laptopcomputer")
                }
                
                // Cloud models — only if Berget API key is configured
                if !settingsManager.bergetKey.isEmpty {
                    Divider().padding(.horizontal, 12).padding(.vertical, 4)
                    
                    Text(localized("cloud_models"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                    
                    modelDropdownRow(modelId: "berget-kb-whisper-large", icon: "cloud")
                }
            }
            .padding(.vertical, 8)
            .frame(width: 260)
        }
    }
    
    @ViewBuilder
    func modelDropdownRow(modelId: String, icon: String) -> some View {
        let isDownloaded = modelManager.isModelDownloaded(modelId)
        let isCloud = modelId.starts(with: "berget-")
        let isDownloading = modelManager.isDownloading[modelId] == true
        let progress = modelManager.downloadProgress[modelId] ?? 0
        
        Button(action: {
            selectedModel = modelId
            showModelPopover = false
            
            // If the model isn't downloaded yet, start downloading immediately
            if !isDownloaded && !isCloud && !isDownloading {
                Task {
                    await downloadModel(modelId)
                }
            }
        }) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                Text(modelManager.displayName(for: modelId))
                    .foregroundColor(isDownloaded || isCloud ? .primary : .secondary)
                
                if isDownloading {
                    Spacer()
                    AccentSpinner(size: 12, lineWidth: 1.5)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primaryAccent)
                        .monospacedDigit()
                } else if !isDownloaded && !isCloud {
                    Text(modelManager.getModelSizeString(modelId))
                        .font(.system(size: 11))
                        .foregroundColor(.textTertiary)
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.textTertiary)
                } else {
                    Spacer()
                }
                
                if selectedModel == modelId {
                    Image(systemName: "checkmark")
                        .foregroundColor(.primaryAccent)
                        .font(.system(size: 12, weight: .semibold))
                } else if isDownloaded || isCloud {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.textTertiary)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    func getLanguageFlag(_ code: String) -> String {
        switch code {
        case "auto": return "🌐"
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
        default: return "🏳️"
        }
    }
    
    func getModelIcon(_ modelId: String) -> String {
        if modelId.starts(with: "kb_whisper-") || modelId.starts(with: "openai_whisper-") {
            return "laptopcomputer"
        } else if modelId == "berget-kb-whisper-large" {
            return "cloud"
        } else if modelId.starts(with: "cloud-") {
            return "cloud.fill"
        } else {
            return "cube"
        }
    }
}

struct FeatureCard: View {
    let icon: String
    let title: String
    var gradient: LinearGradient = LinearGradient.accentGradient
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.primaryAccent.opacity(0.12))
                        .frame(width: 80, height: 80)
                        .scaleEffect(isHovered ? 1.1 : 1.0)
                    
                    Image(systemName: icon)
                        .font(.system(size: 36))
                        .foregroundColor(.primaryAccent)
                }
                
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 160, height: 160)
            .glassCard()
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primaryAccent.opacity(isHovered ? 0.3 : 0), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}


