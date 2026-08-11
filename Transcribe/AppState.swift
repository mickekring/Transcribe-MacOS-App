import SwiftUI
import TranscribeKit

class AppState: ObservableObject {
    @Published var currentTranscriptionURL: URL?
    @Published var showTranscriptionView = false
    @Published var showRecordingView = false
    @Published var showSystemAudioView = false

    /// URL for which `startAccessingSecurityScopedResource()` returned true.
    /// Only these URLs must be balanced with a stop call.
    private var securityScopedURL: URL?

    func openFileForTranscription(_ url: URL, isSecurityScoped: Bool = false) {
        // Release any previously accessed security-scoped resource before replacing it
        stopAccessingSecurityScopedResource()
        if isSecurityScoped && url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
        currentTranscriptionURL = url
        showTranscriptionView = true
    }

    func closeTranscriptionView() {
        showTranscriptionView = false
        currentTranscriptionURL = nil
        stopAccessingSecurityScopedResource()
    }

    private func stopAccessingSecurityScopedResource() {
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
    }
}
