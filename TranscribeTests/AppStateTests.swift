import Foundation
import Testing
@testable import Transcribe

@MainActor
struct AppStateTests {
    private let file = URL(fileURLWithPath: "/tmp/example.m4a")

    @Test func navigatesFreelyWhenNothingIsUnsaved() {
        let state = AppState()
        state.navigate(to: .recording)
        #expect(state.screen == .recording)
        state.navigate(to: .systemAudio)
        #expect(state.screen == .systemAudio)
        #expect(state.pendingNavigation == nil)
    }

    @Test func asksBeforeLeavingARecording() {
        let state = AppState()
        state.navigate(to: .recording)
        state.unsavedWork = .recordingInProgress

        // A status-bar "New Recording", a dropped file, Back — all arrive here
        state.navigate(to: .transcription(file))
        #expect(state.screen == .recording, "must not leave before the user confirms")
        #expect(state.pendingNavigation == .transcription(file))
    }

    @Test func cancellingKeepsTheRecording() {
        let state = AppState()
        state.navigate(to: .recording)
        state.unsavedWork = .untranscribedRecording
        state.navigate(to: .home)
        state.cancelPendingNavigation()

        #expect(state.screen == .recording)
        #expect(state.unsavedWork == .untranscribedRecording)
        #expect(state.pendingNavigation == nil)
    }

    @Test func confirmingDiscardsAndNavigates() {
        let state = AppState()
        state.navigate(to: .systemAudio)
        state.unsavedWork = .recordingInProgress
        state.navigate(to: .home)
        state.confirmPendingNavigation()

        #expect(state.screen == .home)
        #expect(state.unsavedWork == nil)
        #expect(state.pendingNavigation == nil)
    }

    @Test func handingARecordingToTranscriptionNeedsNoConfirmation() {
        let state = AppState()
        state.navigate(to: .recording)
        state.unsavedWork = .untranscribedRecording
        state.transcribeRecording(at: file)

        #expect(state.screen == .transcription(file))
        #expect(state.currentTranscriptionURL == file)
        #expect(state.unsavedWork == nil)
    }

    @Test func closingTheWindowResetsTheRoute() {
        // Reopening the window must not silently re-run the transcription
        let state = AppState()
        state.openFileForTranscription(file)
        #expect(state.screen == .transcription(file))
        state.mainWindowDidClose()

        #expect(state.screen == .home)
        #expect(state.currentTranscriptionURL == nil)
    }

    @Test func navigatingToTheCurrentScreenIsANoOp() {
        let state = AppState()
        state.navigate(to: .recording)
        state.unsavedWork = .recordingInProgress
        state.navigate(to: .recording)
        #expect(state.pendingNavigation == nil)
    }

    @Test(arguments: [
        ("meeting.m4a", true), ("talk.MP3", true), ("clip.mov", true), ("video.mp4", true),
        ("voice.wav", true), ("sound.aiff", true), ("sound.caf", true), ("movie.m4v", true),
        ("notes.txt", false), ("picture.png", false), ("archive.zip", false), ("noextension", false),
    ])
    func acceptsWhatTheOpenPanelAccepts(name: String, expected: Bool) {
        #expect(ContentView.isTranscribable(URL(fileURLWithPath: "/tmp/\(name)")) == expected)
    }

    @Test func clockFormatting() {
        #expect(formatClock(0) == "00:00.0")
        #expect(formatClock(35.24) == "00:35.2")
        #expect(formatClock(75.9) == "01:15.9")
        #expect(formatClock(3725, tenths: false) == "1:02:05")
        #expect(formatClock(-3) == "00:00.0")
        #expect(formatClock(.nan) == "00:00.0")
    }

    /// Recordings made in the app live only in its temp folder, so leaving
    /// them untranscribed must ask; a file the user opened stays on disk.
    @Test func recognisesRecordingsMadeInTheApp() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Transcribe")
        #expect(AppState.isAppRecording(temp.appendingPathComponent("Recordings/a.m4a")))
        #expect(AppState.isAppRecording(temp.appendingPathComponent("SystemAudio/b.m4a")))
        #expect(AppState.isAppRecording(temp.appendingPathComponent("QuickRecordings/c.m4a")))
        #expect(!AppState.isAppRecording(temp.appendingPathComponent("YouTube/d.m4a")))
        #expect(!AppState.isAppRecording(temp.appendingPathComponent("RecordingsElsewhere/e.m4a")))
        #expect(!AppState.isAppRecording(URL(fileURLWithPath: "/Users/someone/Desktop/meeting.m4a")))
    }
}
