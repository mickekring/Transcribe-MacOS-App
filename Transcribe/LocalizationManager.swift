import SwiftUI

class LocalizationManager: ObservableObject {
    nonisolated(unsafe) static let shared = LocalizationManager()
    
    @AppStorage("appLanguage") var appLanguage: String = "en" {
        didSet {
            updateLanguage()
        }
    }
    
    @Published var currentLanguage: String = "en"
    
    private init() {
        // First launch (no stored choice): follow the system language.
        // Swedish macOS -> Swedish UI, Norwegian (Bokmål/Nynorsk) -> Norwegian,
        // everything else -> English. The user can override in Settings.
        if UserDefaults.standard.object(forKey: "appLanguage") == nil {
            appLanguage = Self.defaultLanguageFromSystem()
        }
        currentLanguage = appLanguage
    }

    private static func defaultLanguageFromSystem() -> String {
        let systemCode = Locale.preferredLanguages.first
            .map { Locale(identifier: $0).language.languageCode?.identifier ?? "" } ?? ""
        switch systemCode {
        case "sv": return "sv"
        case "nb", "nn", "no": return "no"
        default: return "en"
        }
    }
    
    func updateLanguage() {
        currentLanguage = appLanguage
        // Force UI refresh
        objectWillChange.send()
    }
    
    func localizedString(_ key: String) -> String {
        let bundle = languageBundle()
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }
    
    private func languageBundle() -> Bundle {
        if let path = Bundle.main.path(forResource: currentLanguage, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return Bundle.main
    }
}

// Convenience function for localization
func localized(_ key: String) -> String {
    LocalizationManager.shared.localizedString(key)
}

