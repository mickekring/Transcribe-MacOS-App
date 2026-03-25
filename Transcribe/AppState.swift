import SwiftUI

class AppState: ObservableObject {
    @Published var currentTranscriptionURL: URL?
    @Published var showTranscriptionView = false
    @Published var showRecordingView = false
    @Published var showSystemAudioView = false
    
    func openFileForTranscription(_ url: URL) {
        currentTranscriptionURL = url
        showTranscriptionView = true
    }
}