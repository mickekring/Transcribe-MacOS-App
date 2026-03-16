import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var localizationManager = LocalizationManager.shared
    @State private var selectedSection = "general"
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient.accentGradient)
                    Text(localized("settings"))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundColor(.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                
                Divider()
                    .foregroundColor(.borderLight)
                
                // Menu Items
                ScrollView {
                    VStack(spacing: 2) {
                        // General Section
                        SectionHeader(title: localized("general").uppercased())
                        
                        SettingsMenuItem(
                            icon: "gearshape",
                            title: localized("general"),
                            isSelected: selectedSection == "general",
                            action: { selectedSection = "general" }
                        )
                        
                        SettingsMenuItem(
                            icon: "key",
                            title: localized("api_keys"),
                            isSelected: selectedSection == "api",
                            action: { selectedSection = "api" }
                        )
                        
                        // Transcribe Section
                        SectionHeader(title: localized("transcription").uppercased())
                            .padding(.top, 16)
                        
                        SettingsMenuItem(
                            icon: "internaldrive",
                            title: localized("downloaded_models"),
                            isSelected: selectedSection == "local_models",
                            action: { selectedSection = "local_models" }
                        )
                        
                        SettingsMenuItem(
                            icon: "cloud",
                            title: localized("cloud_models"),
                            isSelected: selectedSection == "cloud_models",
                            action: { selectedSection = "cloud_models" }
                        )
                        
                        // Language Models Section
                        SectionHeader(title: localized("language_models").uppercased())
                            .padding(.top, 16)
                        
                        SettingsMenuItem(
                            icon: "laptopcomputer",
                            title: localized("local_models"),
                            isSelected: selectedSection == "llm_local",
                            action: { selectedSection = "llm_local" }
                        )
                        
                        SettingsMenuItem(
                            icon: "cloud",
                            title: localized("cloud_models"),
                            isSelected: selectedSection == "llm_cloud",
                            action: { selectedSection = "llm_cloud" }
                        )
                        
                        // Process Text Section
                        SectionHeader(title: localized("process_text").uppercased())
                            .padding(.top, 16)
                        
                        SettingsMenuItem(
                            icon: "text.bubble",
                            title: localized("prompts"),
                            isSelected: selectedSection == "prompts",
                            action: { selectedSection = "prompts" }
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 16)
                }
            }
            .background(Color.surfaceBackground)
            .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 380)
            .toolbar(removing: .sidebarToggle)
            
        } detail: {
            // Detail view based on selection
            ZStack {
                Color.surfaceBackground
                    .ignoresSafeArea()
                
                ScrollView {
                    switch selectedSection {
                    case "general":
                        GeneralSettingsView()
                    case "local_models":
                        LocalModelsView()
                    case "cloud_models":
                        CloudModelsView()
                    case "api":
                        APIKeysView()
                    case "llm_local":
                        LLMLocalModelsView()
                    case "llm_cloud":
                        LLMCloudModelsView()
                    case "prompts":
                        TextProcessingPromptsView()
                    default:
                        GeneralSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .frame(width: 1040, height: 640)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var localizationManager = LocalizationManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient.accentGradient)
                Text(localized("general"))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            
            VStack(alignment: .leading, spacing: 32) {
                // App Language
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text(localized("app_language"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.textPrimary)
                        } icon: {
                            Image(systemName: "globe")
                                .font(.system(size: 18))
                                .foregroundStyle(LinearGradient.accentGradient)
                        }
                        
                        Picker("", selection: $localizationManager.appLanguage) {
                            Text(localized("english")).tag("en")
                            Text(localized("swedish")).tag("sv")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                        .onChange(of: localizationManager.appLanguage) { newValue in
                            localizationManager.updateLanguage()
                        }
                        
                        Text(localized("app_language_description"))
                            .font(.system(size: 12))
                            .foregroundColor(.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LocalModelsView: View {
    @StateObject private var modelManager = ModelManager.shared
    @State private var modelToDelete: String?
    
    private var downloadedModelsSorted: [String] {
        modelManager.downloadedModels.sorted()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "internaldrive")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient.accentGradient)
                Text(localized("downloaded_models"))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            
            if downloadedModelsSorted.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 48))
                        .foregroundColor(.textTertiary)
                    
                    Text(localized("no_models_downloaded"))
                        .font(.system(size: 14))
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 15) {
                            Label {
                                Text(localized("downloaded_models"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.primaryAccent)
                            }
                            
                            Text(localized("downloaded_models_description"))
                                .font(.system(size: 12))
                                .foregroundColor(.textSecondary)
                            
                            VStack(spacing: 10) {
                                ForEach(downloadedModelsSorted, id: \.self) { modelId in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(modelManager.displayName(for: modelId))
                                                .font(.system(size: 13, weight: .medium))
                                            Text(modelManager.getModelSizeString(modelId))
                                                .font(.system(size: 11))
                                                .foregroundColor(.textSecondary)
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            modelToDelete = modelId
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 13))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                        .help(localized("delete_model"))
                                    }
                                    .padding(12)
                                    .background(Color.elevatedSurface)
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(localized("delete_model"), isPresented: Binding(
            get: { modelToDelete != nil },
            set: { if !$0 { modelToDelete = nil } }
        )) {
            Button(localized("remove"), role: .destructive) {
                if let modelId = modelToDelete {
                    modelManager.deleteModel(modelId)
                }
                modelToDelete = nil
            }
            Button(localized("cancel"), role: .cancel) {
                modelToDelete = nil
            }
        } message: {
            if let modelId = modelToDelete {
                Text("\(modelManager.displayName(for: modelId)) (\(modelManager.getModelSizeString(modelId)))")
            }
        }
    }
}

struct CloudModelsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cloud")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient.accentGradient)
                Text(localized("cloud_models"))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            
            VStack(alignment: .leading, spacing: 25) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 15) {
                        Label {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(settingsManager.bergetKey.isEmpty ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                Text("Berget")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                            }
                        } icon: {
                            Image(systemName: "cloud")
                                .font(.system(size: 18))
                                .foregroundStyle(LinearGradient.accentGradient)
                        }
                        
                        Text(localized("cloud_transcription_description"))
                            .font(.system(size: 13))
                            .foregroundColor(.textSecondary)
                        
                        Divider()
                        
                        if !settingsManager.bergetKey.isEmpty {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("KB Whisper Large")
                                        .font(.system(size: 13, weight: .medium))
                                    Text(localized("cloud_transcription_model_subtitle"))
                                        .font(.system(size: 11))
                                        .foregroundColor(.textSecondary)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                    Text(localized("available"))
                                        .font(.system(size: 11))
                                        .foregroundColor(.primaryAccent)
                                }
                            }
                            .padding(12)
                            .background(Color.elevatedSurface)
                            .cornerRadius(8)
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "key")
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                                Text(localized("api_key_required"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ModelRow: View {
    let modelId: String
    let name: String
    let size: String
    let description: String
    let isDownloaded: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let onDownload: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                    
                    if isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(size)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            
            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35)
                }
            } else if isDownloaded {
                Button(action: onDelete) {
                    Text(localized("remove"))
                        .font(.caption)
                        .frame(width: 70)
                }
                .buttonStyle(.bordered)
            } else {
                Button(action: onDownload) {
                    Text(localized("download"))
                        .font(.caption)
                        .frame(width: 70)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.elevatedSurface)
        .cornerRadius(8)
    }
}

struct CloudModelRow: View {
    let provider: String
    let model: String
    let status: String
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider)
                    .font(.system(size: 13, weight: .medium))
                
                Text(model)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(status)
                .font(.caption)
                .foregroundColor(status == "Available" ? .green : .orange)
        }
        .padding(12)
        .background(Color.elevatedSurface)
        .cornerRadius(8)
    }
}

struct APIKeysView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var localizationManager = LocalizationManager.shared
    @State private var tempBergetKey = ""
    @State private var showBergetKey = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "key")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient.accentGradient)
                Text(localized("api_keys"))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            
            VStack(alignment: .leading, spacing: 32) {
                // Berget
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text("Berget 🇸🇪")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.textPrimary)
                        } icon: {
                            Image(systemName: "mountain.2")
                                .font(.system(size: 18))
                                .foregroundStyle(LinearGradient.accentGradient)
                        }
                        
                        Text(localized("berget_cloud_service_description"))
                            .font(.system(size: 12))
                            .foregroundColor(.textSecondary)
                        
                        HStack {
                            if showBergetKey {
                                TextField(localized("api_key"), text: $tempBergetKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 400)
                            } else {
                                SecureField(localized("api_key"), text: $tempBergetKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 400)
                            }
                            
                            Button(action: { showBergetKey.toggle() }) {
                                Image(systemName: showBergetKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            
                            Button(localized("save")) {
                                settingsManager.saveAPIKey(tempBergetKey, for: .berget)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(tempBergetKey.isEmpty)
                            
                            if !settingsManager.bergetKey.isEmpty {
                                Button(localizationManager.currentLanguage == "sv" ? "Ta bort" : "Remove") {
                                    settingsManager.saveAPIKey("", for: .berget)
                                    tempBergetKey = ""
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                            }
                        }
                        
                        Link(localized("get_api_key_berget"), destination: URL(string: "https://berget.ai")!)
                            .font(.system(size: 12))
                            .foregroundColor(.primaryAccent)
                    }
                }
                
                // Ollama
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text("Ollama")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.textPrimary)
                        } icon: {
                            Image(systemName: "server.rack")
                                .font(.system(size: 18))
                                .foregroundStyle(LinearGradient.accentGradient)
                        }
                        
                        Text(localized("ollama_description"))
                            .font(.system(size: 12))
                            .foregroundColor(.textSecondary)
                        
                        HStack {
                            TextField(localized("host_url"), text: $settingsManager.ollamaHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 400)
                            
                            Button(localized("test_connection")) {
                                Task {
                                    await settingsManager.checkOllamaConnection()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                        
                        if !settingsManager.ollamaConnectionStatus.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: settingsManager.ollamaModels.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(settingsManager.ollamaModels.isEmpty ? .orange : .green)
                                Text(settingsManager.ollamaConnectionStatus)
                                    .font(.system(size: 12))
                                    .foregroundColor(.textSecondary)
                            }
                        }
                        
                        if !settingsManager.ollamaModels.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(localized("available_models"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.textSecondary)
                                
                                ForEach(settingsManager.ollamaModels, id: \.self) { model in
                                    HStack {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 6))
                                            .foregroundColor(.green)
                                        Text(model)
                                            .font(.system(size: 12))
                                            .foregroundColor(.textPrimary)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            tempBergetKey = settingsManager.bergetKey
        }
    }
}

struct LLMLocalModelsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient.accentGradient)
                Text(localized("local_models"))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    // Ollama Models
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 15) {
                            Label {
                                Text("Ollama")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                            } icon: {
                                Image(systemName: "laptopcomputer")
                                    .font(.system(size: 18))
                                    .foregroundStyle(LinearGradient.accentGradient)
                            }
                            
                            Text(localized("ollama_llm_description"))
                                .font(.system(size: 12))
                                .foregroundColor(.textSecondary)
                            
                            Divider()
                            
                            // Connection Status
                            HStack {
                                Text(localized("host_url") + ":")
                                    .font(.subheadline)
                                TextField("", text: $settingsManager.ollamaHost)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                
                                Button(localized("test_connection")) {
                                    Task {
                                        await settingsManager.checkOllamaConnection()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            
                            if !settingsManager.ollamaConnectionStatus.isEmpty {
                                Text(settingsManager.ollamaConnectionStatus)
                                    .font(.caption)
                                    .foregroundColor(settingsManager.ollamaConnectionStatus.contains("Connected") ? .green : .orange)
                            }
                            
                            // Available Models
                            if !settingsManager.ollamaModels.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(settingsManager.ollamaModels, id: \.self) { model in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(model)
                                                    .font(.system(size: 13, weight: .medium))
                                                Text(localized("local_language_model"))
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.textSecondary)
                                            }
                                            
                                            Spacer()
                                            
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 16))
                                        }
                                        .padding(12)
                                        .background(Color.elevatedSurface)
                                        .cornerRadius(8)
                                    }
                                }
                            } else if settingsManager.ollamaModels.isEmpty && !settingsManager.ollamaConnectionStatus.isEmpty && !settingsManager.ollamaConnectionStatus.contains("Connected") {
                                HStack(spacing: 4) {
                                    Text(localized("ollama_not_installed"))
                                        .font(.system(size: 12))
                                        .foregroundColor(.textSecondary)
                                    Link("ollama.com", destination: URL(string: "https://ollama.com")!)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primaryAccent)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            Task {
                await settingsManager.checkOllamaConnection()
            }
        }
    }
}

struct BergetLLMModel: Identifiable {
    let id: String        // API model ID
    let displayName: String
    let size: String      // e.g. "70B"
}

struct LLMCloudModelsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
    static let bergetLLMModels: [BergetLLMModel] = [
        BergetLLMModel(id: "meta-llama/Llama-3.3-70B-Instruct", displayName: "Llama 3.3 70B Instruct", size: "70B"),
        BergetLLMModel(id: "meta-llama/Llama-3.1-8B-Instruct", displayName: "Llama 3.1 8B Instruct", size: "8B"),
        BergetLLMModel(id: "mistralai/Mistral-Small-3.2-24B-Instruct-2506", displayName: "Mistral Small 3.2 24B", size: "24B"),
        BergetLLMModel(id: "openai/gpt-oss-120b", displayName: "GPT-OSS 120B", size: "120B"),
        BergetLLMModel(id: "zai-org/GLM-4.7", displayName: "GLM 4.7", size: ""),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "cloud")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient.accentGradient)
                Text(localized("cloud_models"))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    // Berget Models (GDPR safe)
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 15) {
                            Label {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(settingsManager.bergetKey.isEmpty ? Color.gray : Color.green)
                                        .frame(width: 8, height: 8)
                                    Text("Berget AI")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.textPrimary)
                                }
                            } icon: {
                                Image(systemName: "cloud")
                                    .font(.system(size: 18))
                                    .foregroundStyle(LinearGradient.accentGradient)
                            }
                            
                            Text(localized("berget_llm_description"))
                                .font(.system(size: 13))
                                .foregroundColor(.textSecondary)
                            
                            if settingsManager.bergetKey.isEmpty {
                                Text(localized("api_key_required"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                            }
                            
                            Divider()
                            
                            VStack(spacing: 8) {
                                ForEach(Self.bergetLLMModels) { model in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(model.displayName)
                                                .font(.system(size: 13, weight: .medium))
                                            if !model.size.isEmpty {
                                                Text(model.size)
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.textSecondary)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        Circle()
                                            .fill(settingsManager.bergetKey.isEmpty ? Color.gray.opacity(0.5) : Color.green)
                                            .frame(width: 8, height: 8)
                                    }
                                    .padding(12)
                                    .background(Color.elevatedSurface)
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TextProcessingPromptsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var expandedPromptId: UUID?
    @State private var editingName: String = ""
    @State private var editingPromptText: String = ""
    @State private var promptToDelete: TextProcessingPrompt?
    @State private var isAddingNew = false
    @State private var newName: String = ""
    @State private var newPromptText: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "text.bubble")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient.accentGradient)
                Text(localized("process_text"))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label {
                                Text(localized("prompts"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                            } icon: {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(LinearGradient.accentGradient)
                            }
                            
                            Text(localized("prompts_settings_description"))
                                .font(.system(size: 12))
                                .foregroundColor(.textSecondary)
                            
                            Divider()
                            
                            // Prompt list
                            VStack(spacing: 10) {
                                ForEach(settingsManager.textProcessingPrompts) { prompt in
                                    promptRow(for: prompt)
                                }
                            }
                            
                            // Add button
                            if isAddingNew {
                                newPromptEditor
                            } else {
                                Button(action: { isAddingNew = true }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 14))
                                        Text(localized("add_prompt"))
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                    .foregroundColor(.primaryAccent)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(localized("delete_prompt"), isPresented: Binding(
            get: { promptToDelete != nil },
            set: { if !$0 { promptToDelete = nil } }
        )) {
            Button(localized("remove"), role: .destructive) {
                if let prompt = promptToDelete {
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textPrimary)
                    
                    if expandedPromptId != prompt.id {
                        Text(prompt.prompt)
                            .font(.system(size: 11))
                            .foregroundColor(.textSecondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                if expandedPromptId != prompt.id {
                    HStack(spacing: 8) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editingName = prompt.name
                                editingPromptText = prompt.prompt
                                expandedPromptId = prompt.id
                            }
                        }) {
                            Image(systemName: "pencil")
                                .font(.system(size: 13))
                                .foregroundColor(.textSecondary)
                        }
                        .buttonStyle(.borderless)
                        .help(localized("edit_prompt"))
                        
                        Button(action: { promptToDelete = prompt }) {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundColor(.textSecondary)
                        }
                        .buttonStyle(.borderless)
                        .help(localized("delete_prompt"))
                    }
                }
            }
            
            // Expanded editor
            if expandedPromptId == prompt.id {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(localized("prompt_name"), text: $editingName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                    
                    TextEditor(text: $editingPromptText)
                        .font(.system(size: 12))
                        .frame(height: 100)
                        .padding(4)
                        .background(Color.surfaceBackground)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.borderLight, lineWidth: 0.5)
                        )
                    
                    HStack {
                        Button(localized("cancel")) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedPromptId = nil
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        Button(localized("save")) {
                            var updated = prompt
                            updated.name = editingName
                            updated.prompt = editingPromptText
                            settingsManager.updatePrompt(updated)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedPromptId = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(editingName.isEmpty || editingPromptText.isEmpty)
                    }
                }
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color.elevatedSurface)
        .cornerRadius(8)
    }
    
    // MARK: - New Prompt Editor
    
    private var newPromptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(localized("prompt_name"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            
            TextEditor(text: $newPromptText)
                .font(.system(size: 12))
                .frame(height: 100)
                .padding(4)
                .background(Color.surfaceBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.borderLight, lineWidth: 0.5)
                )
            
            HStack {
                Button(localized("cancel")) {
                    isAddingNew = false
                    newName = ""
                    newPromptText = ""
                }
                .buttonStyle(.bordered)
                
                Button(localized("save")) {
                    let prompt = TextProcessingPrompt(name: newName, prompt: newPromptText)
                    settingsManager.addPrompt(prompt)
                    isAddingNew = false
                    newName = ""
                    newPromptText = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.isEmpty || newPromptText.isEmpty)
            }
        }
        .padding(12)
        .background(Color.elevatedSurface)
        .cornerRadius(8)
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.borderLight, lineWidth: 0.5)
        )
    }
}

struct SectionHeader: View {
    let title: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
    }
}

struct SettingsMenuItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? LinearGradient.accentGradient : LinearGradient(
                        colors: [Color.textSecondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .textPrimary : .textSecondary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.hoverBackground : (isHovered ? Color.hoverBackground.opacity(0.5) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsManager())
}
