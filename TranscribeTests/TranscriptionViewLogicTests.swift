import Foundation
import Testing
import TranscribeKit
@testable import Transcribe

/// The rules of the transcription view that are pure functions of their
/// inputs: time and transcript formatting, seek clamping, which mode an
/// export really gets, and the Markdown emphasis pattern.
struct TranscriptionViewLogicTests {

    // MARK: - Time formatting

    @Test func formatsTimeAsMinutesAndSeconds() {
        #expect(TranscriptionViewLogic.formatTime(0) == "00:00")
        #expect(TranscriptionViewLogic.formatTime(9.99) == "00:09")
        #expect(TranscriptionViewLogic.formatTime(65) == "01:05")
        // Minutes keep counting past the hour, like the speaker view's
        // timestamps (SpeakerTranscriptFormatter)
        #expect(TranscriptionViewLogic.formatTime(3725) == "62:05")
    }

    // MARK: - Timestamps mode

    @Test func timestampEntriesAreSeparateParagraphs() {
        let segments = [
            TranscriptionSegmentData(start: 0, end: 4, text: " Hej och välkomna. ", words: nil),
            TranscriptionSegmentData(start: 65.2, end: 70, text: "Vi börjar.", words: nil),
        ]
        // A blank line between entries: Markdown joins lines that are only
        // separated by a single newline into one paragraph
        #expect(TranscriptionViewLogic.timestampedTranscript(segments)
                == "[00:00] Hej och välkomna.\n\n[01:05] Vi börjar.")
        #expect(TranscriptionViewLogic.timestampedTranscript([]) == "")
    }

    // MARK: - Segments mode

    @Test func eachSentenceBecomesAParagraph() {
        #expect(TranscriptionViewLogic.sentenceParagraphs("Hej där. Hur mår du? Bra! Tack.")
                == "Hej där.\n\nHur mår du?\n\nBra!\n\nTack.")
    }

    @Test(arguments: [
        "Vi ses t.ex. på måndag kl. 14 i stan.",
        "Det gäller bl.a. Sverige och Norge.",
        "Møtet er f.eks. Mandag kl. 9 presis.",
        "Send it to Dr. Andersson, e.g. Monday.",
        "Boken av A. Lindgren kom ca. 1945 ut.",
        "Han sa nej... och gick sedan hem.",
    ])
    func abbreviationsDoNotEndASentence(text: String) {
        #expect(TranscriptionViewLogic.sentenceParagraphs(text) == text)
    }

    @Test func splitsAfterTheSentenceThatContainsAnAbbreviation() {
        #expect(TranscriptionViewLogic.sentenceParagraphs("Vi ses kl. 14 i Stockholm. Sedan äter vi.")
                == "Vi ses kl. 14 i Stockholm.\n\nSedan äter vi.")
        // An ellipsis followed by a capital starts a new sentence
        #expect(TranscriptionViewLogic.sentenceParagraphs("Jag vet inte... Vi får se.")
                == "Jag vet inte...\n\nVi får se.")
        // Numbers with a period inside are not abbreviations
        #expect(TranscriptionViewLogic.sentenceParagraphs("Mötet slutar 14.30. Sedan går vi.")
                == "Mötet slutar 14.30.\n\nSedan går vi.")
    }

    @Test func oneLetterWordsEndSentencesButInitialsDoNot() {
        // Swedish and Norwegian sentences often end in "i"
        #expect(TranscriptionViewLogic.sentenceParagraphs("Det är huset vi bor i. Sedan flyttade vi.")
                == "Det är huset vi bor i.\n\nSedan flyttade vi.")
        #expect(TranscriptionViewLogic.sentenceParagraphs("Astrid A. Lindgren skrev den.")
                == "Astrid A. Lindgren skrev den.")
    }

    @Test func splitsScriptsWithoutLetterCase() {
        // No lowercase to hold a period back: every sentence end splits
        #expect(TranscriptionViewLogic.sentenceParagraphs("هذه جملة. هذه أخرى.")
                == "هذه جملة.\n\nهذه أخرى.")
    }

    @Test func leavesTextWithoutSentenceBreaksUnchanged() {
        #expect(TranscriptionViewLogic.sentenceParagraphs("") == "")
        #expect(TranscriptionViewLogic.sentenceParagraphs("Slut.") == "Slut.")
        #expect(TranscriptionViewLogic.sentenceParagraphs("ett två  tre") == "ett två  tre")
        // Nothing follows the last period, so there is nothing to separate
        #expect(TranscriptionViewLogic.sentenceParagraphs("Slut. ") == "Slut. ")
    }

    // MARK: - Seeking

    @Test func seekWithinTheAudioKeepsItsTarget() {
        #expect(TranscriptionViewLogic.seekTarget(for: 12.5, duration: 60) == 12.5)
        #expect(TranscriptionViewLogic.seekTarget(for: 0, duration: 60) == 0)
        #expect(TranscriptionViewLogic.seekTarget(for: 59.99, duration: 60) == 59.99)
    }

    @Test func seekBeforeTheStartClampsToZero() {
        #expect(TranscriptionViewLogic.seekTarget(for: -3, duration: 60) == 0)
    }

    @Test func seekAtOrPastTheEndEndsPlayback() {
        // nil = stop and rewind instead of handing AVAudioPlayer its own
        // duration, which makes a playing player wrap around to 0:00
        #expect(TranscriptionViewLogic.seekTarget(for: 60, duration: 60) == nil)
        #expect(TranscriptionViewLogic.seekTarget(for: 75, duration: 60) == nil)
        // The +10 s button within the last ten seconds asks for exactly the duration
        #expect(TranscriptionViewLogic.seekTarget(for: min(55 + 10, 60), duration: 60) == nil)
        // No playable audio
        #expect(TranscriptionViewLogic.seekTarget(for: 0, duration: 0) == nil)
    }

    // MARK: - Export mode

    @Test func plainModesExportAsThemselves() {
        for hasSegments in [false, true] {
            for hasSpeakerTurns in [false, true] {
                #expect(TranscriptionViewLogic.exportedMode(for: .transcript, hasSegments: hasSegments, hasSpeakerTurns: hasSpeakerTurns) == .transcript)
                #expect(TranscriptionViewLogic.exportedMode(for: .segments, hasSegments: hasSegments, hasSpeakerTurns: hasSpeakerTurns) == .segments)
            }
        }
    }

    @Test func timestampsNeedSegments() {
        #expect(TranscriptionViewLogic.exportedMode(for: .timestamps, hasSegments: true, hasSpeakerTurns: false) == .timestamps)
        #expect(TranscriptionViewLogic.exportedMode(for: .timestamps, hasSegments: false, hasSpeakerTurns: false) == .transcript)
    }

    @Test func speakersNeedSegmentsAndTurns() {
        #expect(TranscriptionViewLogic.exportedMode(for: .speakers, hasSegments: true, hasSpeakerTurns: true) == .speakers)
        // Diarization still running, failed, or never possible: what would
        // be exported is the unlabelled transcript, and is named as such
        #expect(TranscriptionViewLogic.exportedMode(for: .speakers, hasSegments: true, hasSpeakerTurns: false) == .transcript)
        #expect(TranscriptionViewLogic.exportedMode(for: .speakers, hasSegments: false, hasSpeakerTurns: false) == .transcript)
        #expect(TranscriptionViewLogic.exportedMode(for: .speakers, hasSegments: false, hasSpeakerTurns: true) == .transcript)
    }

    // MARK: - Markdown emphasis

    @MainActor
    private func rendered(_ markdown: String) -> String {
        MarkdownTextView.renderMarkdown(markdown, fontSize: 14).string
            .trimmingCharacters(in: .newlines)
    }

    @Test @MainActor func underscoresInsideWordsAreKept() {
        #expect(rendered("Modellen kb_whisper_small användes.") == "Modellen kb_whisper_small användes.")
        #expect(rendered("snake_case and other_name") == "snake_case and other_name")
        #expect(rendered("- nb_whisper_large_coreml") == "•  nb_whisper_large_coreml")
    }

    @Test @MainActor func emphasisMarkersAreStillRemoved() {
        #expect(rendered("Det var _mycket_ bra.") == "Det var mycket bra.")
        #expect(rendered("Det var *mycket* bra.") == "Det var mycket bra.")
        #expect(rendered("Det var **mycket** bra.") == "Det var mycket bra.")
        #expect(rendered("_Hela raden_") == "Hela raden")
    }
}
