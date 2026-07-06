import Foundation
import SwiftUI

struct TranscriptionLanguage: Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let localizationKey: String

    /// Computed on access so picker labels update when the app language changes
    var localizedName: String { localized(localizationKey) }

    static let auto = TranscriptionLanguage(id: "auto", code: "auto", name: "Auto-detect", localizationKey: "language_auto")
    static let swedish = TranscriptionLanguage(id: "sv", code: "sv", name: "Swedish", localizationKey: "language_swedish")
    static let english = TranscriptionLanguage(id: "en", code: "en", name: "English", localizationKey: "language_english")

    static let commonLanguages = [auto, swedish, english]

    static let allLanguages = [
        auto,
        swedish,
        english,
        TranscriptionLanguage(id: "ar", code: "ar", name: "Arabic", localizationKey: "language_arabic"),
        TranscriptionLanguage(id: "zh", code: "zh", name: "Chinese", localizationKey: "language_chinese"),
        TranscriptionLanguage(id: "da", code: "da", name: "Danish", localizationKey: "language_danish"),
        TranscriptionLanguage(id: "nl", code: "nl", name: "Dutch", localizationKey: "language_dutch"),
        TranscriptionLanguage(id: "fi", code: "fi", name: "Finnish", localizationKey: "language_finnish"),
        TranscriptionLanguage(id: "fr", code: "fr", name: "French", localizationKey: "language_french"),
        TranscriptionLanguage(id: "de", code: "de", name: "German", localizationKey: "language_german"),
        TranscriptionLanguage(id: "hi", code: "hi", name: "Hindi", localizationKey: "language_hindi"),
        TranscriptionLanguage(id: "it", code: "it", name: "Italian", localizationKey: "language_italian"),
        TranscriptionLanguage(id: "ja", code: "ja", name: "Japanese", localizationKey: "language_japanese"),
        TranscriptionLanguage(id: "ko", code: "ko", name: "Korean", localizationKey: "language_korean"),
        TranscriptionLanguage(id: "no", code: "no", name: "Norwegian", localizationKey: "language_norwegian"),
        TranscriptionLanguage(id: "pl", code: "pl", name: "Polish", localizationKey: "language_polish"),
        TranscriptionLanguage(id: "pt", code: "pt", name: "Portuguese", localizationKey: "language_portuguese"),
        TranscriptionLanguage(id: "ru", code: "ru", name: "Russian", localizationKey: "language_russian"),
        TranscriptionLanguage(id: "es", code: "es", name: "Spanish", localizationKey: "language_spanish"),
        TranscriptionLanguage(id: "tr", code: "tr", name: "Turkish", localizationKey: "language_turkish"),
        TranscriptionLanguage(id: "uk", code: "uk", name: "Ukrainian", localizationKey: "language_ukrainian")
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