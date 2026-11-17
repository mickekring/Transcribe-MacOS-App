import SwiftUI
import TranscribeKit

/// Which screen the main window shows, and what would be lost by leaving it.
///
/// Navigation is a single value rather than a flag per screen, so two screens
/// can never both be "showing", and every route change — toolbar, status-bar
/// menu, a dropped file, quitting — goes through `navigate(to:)`, which is
/// where unsaved work is protected.
@MainActor
final class AppState: ObservableObject {
    /// One instance for the app: the window scene and the app delegate (quit
    /// confirmation, status-bar menu) must see the same state.
    static let shared = AppState()

    enum Screen: Equatable {
        case home
        case recording
        case systemAudio
        case transcription(URL)
    }

    /// Work on the current screen that exists nowhere else yet.
    enum UnsavedWork: Equatable {
        case recordingInProgress
        case untranscribedRecording
        case unsavedTranscript
    }

    @Published private(set) var screen: Screen = .home

    /// Set by the screen that owns the work; `nil` when nothing would be lost.
    @Published var unsavedWork: UnsavedWork?

    /// A destination waiting for the user to confirm discarding `unsavedWork`.
    /// The root view presents the confirmation while this is set.
    @Published var pendingNavigation: Screen?

    /// URL for which `startAccessingSecurityScopedResource()` returned true.
    /// Only these URLs must be balanced with a stop call.
    private var securityScopedURL: URL?
    /// A file to open once a pending navigation is confirmed.
    private var pendingScopedOpen = false

    private init() {}

    // MARK: - Navigation

    /// Goes to `destination`, asking first if the current screen holds unsaved work.
    func navigate(to destination: Screen, isSecurityScoped: Bool = false) {
        guard destination != screen else { return }
        if unsavedWork != nil {
            pendingNavigation = destination
            pendingScopedOpen = isSecurityScoped
            return
        }
        show(destination, isSecurityScoped: isSecurityScoped)
    }

    /// The user agreed to discard the unsaved work.
    func confirmPendingNavigation() {
        guard let destination = pendingNavigation else { return }
        let scoped = pendingScopedOpen
        pendingNavigation = nil
        pendingScopedOpen = false
        unsavedWork = nil
        show(destination, isSecurityScoped: scoped)
    }

    func cancelPendingNavigation() {
        pendingNavigation = nil
        pendingScopedOpen = false
    }

    /// Leaves the current screen without asking. For screens that have
    /// already confirmed with the user or handed their work on.
    func goHome() {
        unsavedWork = nil
        show(.home, isSecurityScoped: false)
    }

    /// Hands a finished recording to the transcription screen. The recording
    /// is no longer "unsaved" once it is being transcribed.
    func transcribeRecording(at url: URL) {
        unsavedWork = nil
        show(.transcription(url), isSecurityScoped: false)
    }

    func openFileForTranscription(_ url: URL, isSecurityScoped: Bool = false) {
        navigate(to: .transcription(url), isSecurityScoped: isSecurityScoped)
    }

    func closeTranscriptionView() {
        goHome()
    }

    /// The main window closed. Its views (and any running transcription) are
    /// gone, so the route must not survive: reopening the window would
    /// otherwise silently start the same transcription again.
    func mainWindowDidClose() {
        pendingNavigation = nil
        unsavedWork = nil
        show(.home, isSecurityScoped: false)
    }

    private func show(_ destination: Screen, isSecurityScoped: Bool) {
        // Release the previous file before taking the next
        stopAccessingSecurityScopedResource()
        if case .transcription(let url) = destination, isSecurityScoped,
           url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
        screen = destination
    }

    private func stopAccessingSecurityScopedResource() {
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
    }

    // MARK: - Convenience

    var currentTranscriptionURL: URL? {
        if case .transcription(let url) = screen { return url }
        return nil
    }

    var isHome: Bool { screen == .home }
}
