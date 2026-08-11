import SwiftUI

public class LocalizationManager: ObservableObject {
    nonisolated(unsafe) public static let shared = LocalizationManager()
    
    @AppStorage("appLanguage") public var appLanguage: String = "en" {
        didSet {
            updateLanguage()
        }
    }
    
    @Published public var currentLanguage: String = "en"
    
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
    
    public func updateLanguage() {
        currentLanguage = appLanguage
        // Force UI refresh
        objectWillChange.send()
    }
    
    public func localizedString(_ key: String) -> String {
        let bundle = languageBundle()
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }
    
    private func languageBundle() -> Bundle {
        // Strings ship as TranscribeKit package resources so macOS and iOS
        // share one table; the app bundle remains a fallback.
        if let path = Bundle.module.path(forResource: currentLanguage, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = Bundle.main.path(forResource: currentLanguage, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return Bundle.module
    }
}

// Convenience function for localization
public func localized(_ key: String) -> String {
    LocalizationManager.shared.localizedString(key)
}

