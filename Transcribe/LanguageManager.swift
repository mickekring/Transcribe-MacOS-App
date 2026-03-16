import Foundation
import SwiftUI

struct TranscriptionLanguage: Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let localizedName: String
    
    static let auto = TranscriptionLanguage(id: "auto", code: "auto", name: "Auto-detect", localizedName: localized("language_auto"))
    static let swedish = TranscriptionLanguage(id: "sv", code: "sv", name: "Swedish", localizedName: localized("language_swedish"))
    static let english = TranscriptionLanguage(id: "en", code: "en", name: "English", localizedName: localized("language_english"))
    
    static let commonLanguages = [auto, swedish, english]
    
    static let allLanguages = [
        auto,
        swedish,
        english,
        TranscriptionLanguage(id: "ar", code: "ar", name: "Arabic", localizedName: localized("language_arabic")),
        TranscriptionLanguage(id: "zh", code: "zh", name: "Chinese", localizedName: localized("language_chinese")),
        TranscriptionLanguage(id: "da", code: "da", name: "Danish", localizedName: localized("language_danish")),
        TranscriptionLanguage(id: "nl", code: "nl", name: "Dutch", localizedName: localized("language_dutch")),
        TranscriptionLanguage(id: "fi", code: "fi", name: "Finnish", localizedName: localized("language_finnish")),
        TranscriptionLanguage(id: "fr", code: "fr", name: "French", localizedName: localized("language_french")),
        TranscriptionLanguage(id: "de", code: "de", name: "German", localizedName: localized("language_german")),
        TranscriptionLanguage(id: "hi", code: "hi", name: "Hindi", localizedName: localized("language_hindi")),
        TranscriptionLanguage(id: "it", code: "it", name: "Italian", localizedName: localized("language_italian")),
        TranscriptionLanguage(id: "ja", code: "ja", name: "Japanese", localizedName: localized("language_japanese")),
        TranscriptionLanguage(id: "ko", code: "ko", name: "Korean", localizedName: localized("language_korean")),
        TranscriptionLanguage(id: "no", code: "no", name: "Norwegian", localizedName: localized("language_norwegian")),
        TranscriptionLanguage(id: "pl", code: "pl", name: "Polish", localizedName: localized("language_polish")),
        TranscriptionLanguage(id: "pt", code: "pt", name: "Portuguese", localizedName: localized("language_portuguese")),
        TranscriptionLanguage(id: "ru", code: "ru", name: "Russian", localizedName: localized("language_russian")),
        TranscriptionLanguage(id: "es", code: "es", name: "Spanish", localizedName: localized("language_spanish")),
        TranscriptionLanguage(id: "tr", code: "tr", name: "Turkish", localizedName: localized("language_turkish")),
        TranscriptionLanguage(id: "uk", code: "uk", name: "Ukrainian", localizedName: localized("language_ukrainian"))
    ]
}

class LanguageManager: ObservableObject {
    nonisolated(unsafe) static let shared = LanguageManager()
    
    @Published var selectedLanguage: TranscriptionLanguage = .auto
    @AppStorage("transcriptionLanguage") private var savedLanguageCode: String = "auto"
    
    private init() {
        loadSavedLanguage()
    }
    
    private func loadSavedLanguage() {
        if let language = TranscriptionLanguage.allLanguages.first(where: { $0.code == savedLanguageCode }) {
            selectedLanguage = language
        } else {
            // Default to auto-detect if no saved language
            selectedLanguage = TranscriptionLanguage.auto
        }
    }
    
    @MainActor
    func selectLanguage(_ language: TranscriptionLanguage) {
        selectedLanguage = language
        savedLanguageCode = language.code
    }
}