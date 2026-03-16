import Foundation
import SwiftUI
import Combine
import Security

// MARK: - Native Keychain Helper

/// Lightweight wrapper around the Security framework for storing API keys.
enum KeychainHelper {
    private static let service = "com.transcribe.api-keys"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Try to update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            // Item doesn't exist yet — add it
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return status == errSecSuccess
    }
}

// Simplified managers that don't have external dependencies for initial build

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentProgress: Double = 0
    @Published var currentTask: String = ""
    @Published var completedTranscriptions: [TranscriptionResult] = []
    
    init() {
        // Simplified init without dependencies
    }
    
    func transcribeFile(_ url: URL) {
        // Placeholder implementation
        isTranscribing = true
        currentTask = "Transcribing \(url.lastPathComponent)"
        
        // Simulate transcription
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.isTranscribing = false
            self?.currentTask = ""
            self?.currentProgress = 0
        }
    }
}

@MainActor
class SettingsManager: ObservableObject {
    @AppStorage("defaultLanguage") var defaultLanguage: String = "sv"
    @AppStorage("enableAutoLanguageDetection") var enableAutoLanguageDetection: Bool = true
    @AppStorage("enableTimestamps") var enableTimestamps: Bool = true
    @AppStorage("enableSpeakerDiarization") var enableSpeakerDiarization: Bool = false
    @AppStorage("preferredLLMProvider") var preferredLLMProvider: String = "ollama"
    @AppStorage("enableLLMEnhancement") var enableLLMEnhancement: Bool = false
    @AppStorage("autoSaveTranscriptions") var autoSaveTranscriptions: Bool = true
    @AppStorage("transcriptionSaveLocation") var transcriptionSaveLocation: String = ""
    
    // API Keys stored securely in Keychain
    @Published var bergetKey: String = ""
    
    // Text processing prompts
    @Published var textProcessingPrompts: [TextProcessingPrompt] = []
    
    // Berget LLM settings
    @AppStorage("selectedBergetLLMModel") var selectedBergetLLMModel: String = "meta-llama/Llama-3.3-70B-Instruct"
    
    // Ollama settings
    @AppStorage("ollamaHost") var ollamaHost: String = "http://127.0.0.1:11434"
    @Published var ollamaModels: [String] = []
    @Published var ollamaConnectionStatus: String = ""
    @AppStorage("selectedOllamaModel") var selectedOllamaModel: String = ""
    
    // Recording settings
    @AppStorage("recordingQuality") var recordingQuality: String = "high"
    @AppStorage("enableNoiseReduction") var enableNoiseReduction: Bool = true
    @AppStorage("enableSilenceTrimming") var enableSilenceTrimming: Bool = true
    @AppStorage("maxRecordingDuration") var maxRecordingDuration: Int = 14400
    
    // UI Settings
    @AppStorage("showStatusBarIcon") var showStatusBarIcon: Bool = true
    @AppStorage("launchAtStartup") var launchAtStartup: Bool = false
    @AppStorage("minimizeToStatusBar") var minimizeToStatusBar: Bool = false
    
    // Privacy settings
    @AppStorage("enableAnalytics") var enableAnalytics: Bool = false
    @AppStorage("localOnlyMode") var localOnlyMode: Bool = false
    @AppStorage("clearHistoryOnQuit") var clearHistoryOnQuit: Bool = false
    
    // Default model and output format as simple strings
    @AppStorage("defaultModel") var defaultModel: String = "kb_whisper-small-coreml"
    @AppStorage("defaultOutputFormat") var defaultOutputFormat: String = "txt"
    
    init() {
        // Migrate API key from UserDefaults to Keychain if needed
        if let legacyKey = UserDefaults.standard.string(forKey: "bergetAPIKey"), !legacyKey.isEmpty {
            if KeychainHelper.set(legacyKey, forKey: "bergetAPIKey") {
                UserDefaults.standard.removeObject(forKey: "bergetAPIKey")
            }
        }
        
        // Load API key from Keychain
        self.bergetKey = KeychainHelper.get("bergetAPIKey") ?? ""
        
        // Load text processing prompts
        loadPrompts()
    }
    
    func saveAPIKey(_ key: String, for provider: APIKeyType) {
        switch provider {
        case .berget:
            bergetKey = key
            KeychainHelper.set(key, forKey: "bergetAPIKey")
        }
    }
    
    func validateAPIKey(_ key: String, for provider: APIKeyType) async -> Bool {
        return !key.isEmpty
    }
    
    func checkOllamaConnection() async {
        // Real Ollama API check
        await MainActor.run {
            self.ollamaConnectionStatus = "Connecting..."
        }
        
        guard let url = URL(string: "\(ollamaHost)/api/tags") else {
            await MainActor.run {
                self.ollamaModels = []
                self.ollamaConnectionStatus = "Invalid URL"
            }
            return
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                await MainActor.run {
                    self.ollamaModels = []
                    self.ollamaConnectionStatus = "Connection failed"
                }
                return
            }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let modelNames = models.compactMap { $0["name"] as? String }
                await MainActor.run {
                    self.ollamaModels = modelNames
                    self.ollamaConnectionStatus = modelNames.isEmpty ? "Connected (no models installed)" : "Connected (\(modelNames.count) models)"
                }
            } else {
                await MainActor.run {
                    self.ollamaModels = []
                    self.ollamaConnectionStatus = "Connected (no models found)"
                }
            }
        } catch {
            await MainActor.run {
                self.ollamaModels = []
                self.ollamaConnectionStatus = "Not running (start Ollama first)"
            }
        }
    }
    
    func resetToDefaults() {
        defaultLanguage = "sv"
        enableAutoLanguageDetection = true
        enableTimestamps = true
        enableSpeakerDiarization = false
        preferredLLMProvider = "ollama"
        enableLLMEnhancement = false
        autoSaveTranscriptions = true
        transcriptionSaveLocation = ""
        ollamaHost = "http://127.0.0.1:11434"
        ollamaModels = []
        ollamaConnectionStatus = ""
        selectedOllamaModel = ""
        recordingQuality = "high"
        enableNoiseReduction = true
        enableSilenceTrimming = true
        maxRecordingDuration = 14400
        showStatusBarIcon = true
        launchAtStartup = false
        minimizeToStatusBar = false
        enableAnalytics = false
        localOnlyMode = false
        clearHistoryOnQuit = false
        defaultModel = "kb_whisper-small-coreml"
        defaultOutputFormat = "txt"
        textProcessingPrompts = Self.defaultPrompts()
        savePrompts()
        // Note: API keys are intentionally NOT reset
    }
    
    // MARK: - Text Processing Prompts
    
    private static let promptsKey = "textProcessingPrompts"
    
    func loadPrompts() {
        guard let data = UserDefaults.standard.data(forKey: Self.promptsKey),
              let prompts = try? JSONDecoder().decode([TextProcessingPrompt].self, from: data) else {
            // First launch: seed with default prompts
            textProcessingPrompts = Self.defaultPrompts()
            savePrompts()
            return
        }
        textProcessingPrompts = prompts
    }
    
    func savePrompts() {
        if let data = try? JSONEncoder().encode(textProcessingPrompts) {
            UserDefaults.standard.set(data, forKey: Self.promptsKey)
        }
    }
    
    func addPrompt(_ prompt: TextProcessingPrompt) {
        textProcessingPrompts.append(prompt)
        savePrompts()
    }
    
    func updatePrompt(_ prompt: TextProcessingPrompt) {
        if let index = textProcessingPrompts.firstIndex(where: { $0.id == prompt.id }) {
            textProcessingPrompts[index] = prompt
            savePrompts()
        }
    }
    
    func deletePrompt(_ prompt: TextProcessingPrompt) {
        textProcessingPrompts.removeAll { $0.id == prompt.id }
        savePrompts()
    }
    
    static func defaultPrompts() -> [TextProcessingPrompt] {
        [
            TextProcessingPrompt(
                name: "Sammanfattning",
                prompt: """
                Du är en assistent som specialiserat sig på att sammanfatta transkriberat tal från möten, intervjuer, föreläsningar och samtal.

                Transkriberad text är ofta ostrukturerad – den innehåller talspråk, utfyllnadsord, upprepningar och sidospår. Din uppgift är att omvandla detta till en tydlig, välstrukturerad och lättläst sammanfattning.

                **Instruktioner:**

                - Identifiera och lyft fram de viktigaste ämnena, diskussionerna och slutsatserna
                - Filtrera bort utfyllnadsord, upprepningar och irrelevanta sidospår
                - Skriv på samma språk som transkriberingen
                - Håll sammanfattningen till ungefär 15–25% av originaltextens längd
                - Använd ett neutralt, professionellt och lättläst språk
                - Lägg inte till tolkningar eller information som inte finns i källtexten

                **Struktur – använd dessa avsnitt om de är relevanta:**

                1. **Översikt** – En till två meningar om vad transkriberingen handlar om och i vilket sammanhang den äger rum
                2. **Huvudpunkter** – De centrala ämnena och diskussionerna, i kortfattad punktform eller löpande text
                3. **Beslut** – Eventuella beslut som fattades (utelämnas om inga beslut förekom)
                4. **Nästa steg** – Åtgärdspunkter, uppgifter eller uppföljningar som nämndes (utelämnas om inga förekom)

                Anpassa strukturen efter innehållet – ett kort samtal behöver inte alla avsnitt.
                """
            ),
            TextProcessingPrompt(
                name: "Åtgärdspunkter",
                prompt: """
                Du är en assistent som specialiserat sig på att extrahera åtgärdspunkter och uppgifter från transkriberat tal.

                Transkriberad text är ofta ostrukturerad – åtgärdspunkter kan vara utspridda, otydligt formulerade eller underförstådda i konversationen. Din uppgift är att identifiera allt som är en uppgift, ett löfte, ett beslut om handling eller en uppföljning – och presentera det tydligt och strukturerat.

                **Instruktioner:**

                - Leta efter explicita åtgärdspunkter ("vi måste", "jag ska", "kom ihåg att", "följ upp") men även implicita sådana som framgår av sammanhanget
                - Inkludera ansvarig person om det framgår av transkriberingen
                - Inkludera deadline eller tidsram om den nämns
                - Formulera varje punkt som en konkret, handlingsorienterad mening – börja gärna med ett verb
                - Skriv på samma språk som transkriberingen
                - Lägg inte till tolkningar eller uppgifter som inte finns i källtexten
                - Om inga åtgärdspunkter finns – ange det tydligt istället för att hitta på

                **Struktur:**

                Presentera åtgärdspunkterna i en tabell med följande kolumner:

                | # | Åtgärd | Ansvarig | Deadline |
                |---|--------|----------|----------|
                | 1 | Beskrivning av uppgiften | Person (om känd) | Datum/tidsram (om känd) |

                Om tabellformat inte passar (t.ex. vid få punkter eller om ingen ansvarig/deadline nämns), använd istället en numrerad lista.

                Avsluta med en kort rad om hur många åtgärdspunkter som identifierades och om något verkade oklart eller behöver förtydligas.
                """
            ),
            TextProcessingPrompt(
                name: "Nyckelpunkter",
                prompt: """
                Du är en assistent som specialiserat sig på att destillera transkriberat tal till dess viktigaste nyckelpunkter.

                Transkriberad text är ofta ostrukturerad och innehåller talspråk, utsvävningar och upprepningar. Din uppgift är att skala bort allt oväsentligt och presentera kärnan av vad som sades – tydligt, koncist och i en form som är enkel att snabbt ta till sig.

                **Instruktioner:**

                - Identifiera de punkter som är mest centrala, återkommande eller som tydligt betonades av talaren/talarna
                - Varje punkt ska vara självbärande – begriplig utan att man läst transkriberingen
                - Formulera punkterna i fullständiga meningar, inte fragmentariska nyckelord
                - Skriv på samma språk som transkriberingen
                - Sträva efter 5–10 punkter beroende på transkriberingens längd och innehåll – varken fler eller färre än innehållet motiverar
                - Prioritera kvalitet framför kvantitet: en träffsäker punkt är bättre än tre utfyllnadspunkter
                - Lägg inte till tolkningar eller information som inte finns i källtexten

                **Struktur:**

                Om transkriberingen täcker tydligt avgränsade ämnen eller teman, gruppera punkterna under korta rubriker:

                **[Tema eller ämne]**
                - Nyckelpunkt
                - Nyckelpunkt

                Om innehållet inte har tydliga teman, presentera punkterna som en rak lista utan rubriker.

                Avsluta med en valfri kommentarsrad om något ämne verkade särskilt centralt, kontroversiellt eller oavslutat i samtalet.
                """
            ),
        ]
    }
}

enum APIKeyType: String {
    case berget = "Berget"
}