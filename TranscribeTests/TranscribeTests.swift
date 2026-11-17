import Foundation
import Testing
@testable import TranscribeKit

// MARK: - Model routing

struct ModelRoutingTests {

    @Test func everyLocalModelHasAnEngine() {
        for modelId in ModelManager.allLocalModels {
            #expect(ModelManager.engine(for: modelId) != nil, "\(modelId) has no engine")
            #expect(ModelManager.engine(for: modelId) != .cloud)
        }
    }

    @Test func familiesRouteToTheirEngine() {
        #expect(ModelManager.engine(for: "kb_whisper-small-coreml") == .whisperKit)
        #expect(ModelManager.engine(for: "nb_whisper-large-coreml") == .whisperKit)
        #expect(ModelManager.engine(for: "openai_whisper-large-v3") == .whisperKit)
        #expect(ModelManager.engine(for: "pianissimo_sv-coreml") == .parakeet)
        #expect(ModelManager.engine(for: "parakeet_tdt-v3-coreml") == .parakeet)
        #expect(ModelManager.engine(for: "berget:KBLab/kb-whisper-large") == .cloud)
        #expect(ModelManager.engine(for: "berget-kb-whisper-large") == .cloud)
        #expect(ModelManager.engine(for: "") == nil)
        #expect(ModelManager.engine(for: "something-else") == nil)
    }

    @Test func parakeetModelsAreNotMistakenForWhisper() {
        // WhisperKitService falls back to a default variant for ids it does
        // not know; a Parakeet id must never reach it.
        for modelId in ModelManager.parakeetModels {
            #expect(!ModelManager.kbModels.contains(modelId))
            #expect(!ModelManager.openAIModels.contains(modelId))
            #expect(ModelManager.engine(for: modelId) == .parakeet)
        }
    }

    @Test func languageSupport() {
        // Pianissimo is Swedish only
        #expect(ModelManager.supports(languageCode: "sv", modelId: "pianissimo_sv-coreml"))
        #expect(ModelManager.supports(languageCode: "auto", modelId: "pianissimo_sv-coreml"))
        #expect(!ModelManager.supports(languageCode: "en", modelId: "pianissimo_sv-coreml"))
        // Parakeet v3 covers 25 European languages — not Norwegian
        #expect(ModelManager.supports(languageCode: "en", modelId: "parakeet_tdt-v3-coreml"))
        #expect(ModelManager.supports(languageCode: "da", modelId: "parakeet_tdt-v3-coreml"))
        #expect(!ModelManager.supports(languageCode: "no", modelId: "parakeet_tdt-v3-coreml"))
        #expect(!ModelManager.supports(languageCode: "ja", modelId: "parakeet_tdt-v3-coreml"))
        // Whisper and cloud models take anything
        #expect(ModelManager.supports(languageCode: "ja", modelId: "openai_whisper-large-v3"))
        #expect(ModelManager.supports(languageCode: "no", modelId: "berget:NbAiLab/nb-whisper-large"))
    }

    @Test func parakeetSpecsArePinnedToACommit() {
        #expect(ParakeetModelSpec.parakeetV3Languages.count == 25)
        for spec in ParakeetModelSpec.all {
            #expect(spec.revision.count == 40, "\(spec.id) must pin a full commit hash")
            #expect(spec.revision.allSatisfy { $0.isHexDigit })
            #expect(!spec.entries.isEmpty)
            #expect(spec.sizeBytes > 100_000_000)
        }
    }
}

// MARK: - Repository listing

struct RepositoryListingTests {

    private func listing(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries)
    }

    @Test func keepsOnlyRequestedTopLevelEntries() throws {
        let data = try listing([
            ["type": "directory", "path": "Encoder.mlmodelc"],
            ["type": "file", "path": "Encoder.mlmodelc/weights/weight.bin", "size": 1000, "lfs": ["oid": "abc"]],
            ["type": "file", "path": "Encoder.mlmodelc/model.mil", "size": 10],
            ["type": "file", "path": "EncoderInt4.mlmodelc/weights/weight.bin", "size": 5000],
            ["type": "file", "path": "vocab.json", "size": 7],
            ["type": "file", "path": "README.md", "size": 3],
        ])
        let files = try HuggingFaceDownloader.parseListing(data, entries: ["Encoder.mlmodelc", "vocab.json"])
        #expect(files.map(\.path).sorted() == ["Encoder.mlmodelc/model.mil", "Encoder.mlmodelc/weights/weight.bin", "vocab.json"])
        #expect(files.first { $0.path.hasSuffix("weight.bin") }?.sha256 == "abc")
        #expect(files.first { $0.path == "vocab.json" }?.sha256 == nil)
    }

    @Test func aMissingRequestedEntryIsAnError() throws {
        let data = try listing([["type": "file", "path": "vocab.json", "size": 7]])
        #expect(throws: ModelDownloadError.self) {
            try HuggingFaceDownloader.parseListing(data, entries: ["vocab.json", "Encoder.mlmodelc"])
        }
    }

    @Test(arguments: ["../evil", "a/../../evil", "/etc/passwd", "a//b", "./a", "a/./b", "a\\b"])
    func rejectsPathsThatEscapeTheDestination(path: String) throws {
        let data = try listing([["type": "file", "path": path, "size": 1]])
        #expect(throws: ModelDownloadError.self) {
            try HuggingFaceDownloader.parseListing(data, entries: nil)
        }
    }

    @Test func rejectsAnEmptyOrMalformedListing() throws {
        #expect(throws: ModelDownloadError.self) {
            try HuggingFaceDownloader.parseListing(Data("[]".utf8), entries: nil)
        }
        #expect(throws: ModelDownloadError.self) {
            try HuggingFaceDownloader.parseListing(Data("{\"error\":\"not found\"}".utf8), entries: nil)
        }
        // A file without a size can't be verified
        let noSize = try listing([["type": "file", "path": "a.bin"]])
        #expect(throws: ModelDownloadError.self) {
            try HuggingFaceDownloader.parseListing(noSize, entries: nil)
        }
    }

    @Test func sha256MatchesAKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try HuggingFaceDownloader.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

// MARK: - Segmenting timed words

struct TranscriptSegmenterTests {

    private func words(_ items: [(String, Double, Double)]) -> [WordTimestamp] {
        items.map { WordTimestamp(word: $0.0, start: $0.1, end: $0.2, confidence: 1) }
    }

    @Test func splitsAtSentenceEnds() {
        let segments = TranscriptSegmenter.segments(from: words([
            ("Hej", 0.0, 0.3), ("där.", 0.3, 0.6), ("Hur", 0.7, 0.9), ("mår", 0.9, 1.1), ("du?", 1.1, 1.4), ("Bra", 1.5, 1.8),
        ]))
        #expect(segments.map(\.text) == ["Hej där.", "Hur mår du?", "Bra"])
        #expect(segments[0].start == 0.0 && segments[0].end == 0.6)
        #expect(segments[1].start == 0.7 && segments[1].end == 1.4)
        #expect(segments[1].words?.count == 3)
    }

    @Test func splitsAtLongPausesWithoutPunctuation() {
        let segments = TranscriptSegmenter.segments(from: words([
            ("ett", 0.0, 0.2), ("två", 0.2, 0.4), ("tre", 2.0, 2.2), ("fyra", 2.2, 2.4),
        ]))
        #expect(segments.map(\.text) == ["ett två", "tre fyra"])
    }

    @Test func capsUnpunctuatedMonologues() {
        let monologue = (0..<100).map { ("ord", Double($0) * 0.3, Double($0) * 0.3 + 0.25) }
        let segments = TranscriptSegmenter.segments(from: words(monologue), maxWords: 40, maxDuration: 20)
        #expect(segments.count >= 3)
        #expect(segments.allSatisfy { ($0.words?.count ?? 0) <= 40 })
        #expect(segments.allSatisfy { $0.end - $0.start <= 20.5 })
        // Nothing lost, nothing duplicated
        #expect(segments.flatMap { $0.words ?? [] }.count == 100)
    }

    @Test func emptyInputGivesNoSegments() {
        #expect(TranscriptSegmenter.segments(from: []).isEmpty)
    }
}

// MARK: - Live commit policy

struct LiveCommitPolicyTests {
    private let policy = LiveCommitPolicy()

    /// Evenly spaced words, one every `spacing` seconds, each `length` long.
    private func words(count: Int, from start: Double, spacing: Double = 0.4, length: Double = 0.3) -> [LiveWord] {
        (0..<count).map { LiveWord(text: "w\($0)", start: start + Double($0) * spacing, end: start + Double($0) * spacing + length) }
    }

    @Test func shortSegmentsAreNeverCut() {
        let w = words(count: 15, from: 0)   // 6 s of speech
        #expect(policy.cut(words: w, segmentStart: 0, segmentEnd: 6) == nil)
    }

    @Test func cutsAtAClearPauseOnceLongEnough() throws {
        // 10 s segment with a 0.9 s pause after the 10th word (around 4 s)
        var w = words(count: 10, from: 0)                 // ends 3.9
        w += words(count: 12, from: 4.8)                  // 4.8 … 9.5
        let cut = try #require(policy.cut(words: w, segmentStart: 0, segmentEnd: 10))
        #expect(cut.wordCount == 10)
        #expect(cut.time > 3.9 && cut.time < 4.8)
    }

    @Test func prefersASentenceEndOverASlightlyLongerPause() throws {
        var w = words(count: 8, from: 0)                  // ends 3.1, gaps 0.1
        w[7].text = "slut."                               // sentence end, then a 0.2 s gap
        w += words(count: 6, from: 3.3)                   // 3.3 … 5.6
        w += words(count: 8, from: 6.1)                   // 0.5 s pause before, no punctuation
        let cut = try #require(policy.cut(words: w, segmentStart: 0, segmentEnd: 10.5))
        #expect(cut.wordCount == 8)
    }

    @Test func neverCutsInsideTheUnsettledTail() {
        // The only real pause is 1 s before the live edge: too fresh to trust
        var w = words(count: 20, from: 0, spacing: 0.4, length: 0.4)   // continuous, ends 8.0
        w += words(count: 2, from: 9.0, spacing: 0.4, length: 0.4)     // pause 8.0–9.0
        #expect(policy.cut(words: w, segmentStart: 0, segmentEnd: 10) == nil)
    }

    @Test func neverCutsRightAtTheStart() {
        // Pause at 1 s, then continuous speech: the head guard protects it
        var w = words(count: 2, from: 0, spacing: 0.4, length: 0.4)     // ends 0.8
        w += words(count: 20, from: 1.8, spacing: 0.4, length: 0.4)     // 1.8 … 9.8
        #expect(policy.cut(words: w, segmentStart: 0, segmentEnd: 10) == nil)
    }

    @Test func forcesACutAtTheHardLimitEvenWithoutAPause() throws {
        let w = words(count: 32, from: 0, spacing: 0.4, length: 0.4)    // 12.8 s, no gaps at all
        let cut = try #require(policy.cut(words: w, segmentStart: 0, segmentEnd: 13))
        // The latest gap that still leaves the tail guard
        let lastCommitted = w[cut.wordCount - 1]
        #expect(lastCommitted.end <= 13 - policy.tailGuard + 0.001)
        #expect(w[cut.wordCount].start >= lastCommitted.end)
        #expect(cut.wordCount > 20)
    }

    @Test func worksOnAnOffsetTimeline() throws {
        // Same shape as the clear-pause case, 100 s into a recording
        var w = words(count: 10, from: 100)
        w += words(count: 12, from: 104.8)
        let cut = try #require(policy.cut(words: w, segmentStart: 100, segmentEnd: 110))
        #expect(cut.wordCount == 10)
        #expect(cut.time > 103.9 && cut.time < 104.8)
    }

    @Test func aCutAlwaysLiesInsideTheSegment() {
        for count in 2...40 {
            let w = words(count: count, from: 50, spacing: 0.37, length: 0.3)
            let end = (w.last?.end ?? 50) + 0.5
            if let cut = policy.cut(words: w, segmentStart: 50, segmentEnd: end) {
                #expect(cut.time >= 50 && cut.time <= end)
                #expect(cut.wordCount >= 1 && cut.wordCount < w.count)
            }
        }
    }
}
