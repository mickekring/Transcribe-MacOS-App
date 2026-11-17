import Foundation
import Testing
@testable import TranscribeKit
// Only these two: WhisperKit and TranscribeKit both have a TranscriptionResult
// and a TranscriptionSegment, and importing the whole module makes every use
// of those names ambiguous.
import class WhisperKit.WhisperKitConfig
import struct WhisperKit.DecodingOptions

// Regression tests for defects found in the TranscribeKit audit. Each suite
// names the behaviour it pins down; none of them needs a model or the network.

/// A scratch directory that is removed when the test is done.
private final class ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitRegressionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates an empty file (and its parent folders) at a path below the directory.
    @discardableResult
    func touch(_ path: String, contents: String = "") throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

// MARK: - Whisper model catalog

struct WhisperModelCatalogTests {

    @Test func everyWhisperModelHasAVariant() {
        for modelId in ModelManager.allLocalModels where ModelManager.engine(for: modelId) == .whisperKit {
            #expect(WhisperKitService.modelVariant(for: modelId) != nil, "\(modelId) has no variant")
        }
    }

    @Test func anUnknownIdHasNoVariantToFallBackOn() {
        // These pass the family check (the prefix) but are not models the app
        // ships; they used to be downloaded as openai_whisper-base.
        #expect(WhisperKitService.modelVariant(for: "openai_whisper-tiny") == nil)
        #expect(WhisperKitService.modelVariant(for: "kb_whisper-huge-coreml") == nil)
        #expect(WhisperKitService.modelVariant(for: "") == nil)
        #expect(WhisperKitService.defaultModelFolder(for: "openai_whisper-tiny", downloadBase: URL(fileURLWithPath: "/base")) == nil)
    }

    @Test @MainActor func anUnknownIdIsRejectedBeforeAnythingIsDownloaded() async {
        await #expect(throws: TranscriptionError.self) {
            try await WhisperKitService.shared.downloadOnly(modelId: "openai_whisper-tiny")
        }
        await #expect(throws: TranscriptionError.self) {
            try await WhisperKitService.shared.initialize(modelId: "openai_whisper-tiny")
        }
        #expect(ModelManager.shared.isDownloading["openai_whisper-tiny"] != true)
    }

    @Test func stagingAreaSitsBesideTheModelFolderInTheHubLayout() throws {
        let base = URL(fileURLWithPath: "/base")
        let folder = try #require(WhisperKitService.defaultModelFolder(for: "openai_whisper-small", downloadBase: base))
        #expect(folder.path == "/base/models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        #expect(WhisperKitService.stagingDirectory(forModelFolder: folder).path
                == "/base/models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/openai_whisper-small")

        // Staging is per model: removing one model's must not touch another's
        let other = try #require(WhisperKitService.defaultModelFolder(for: "openai_whisper-base", downloadBase: base))
        #expect(WhisperKitService.stagingDirectory(forModelFolder: other) != WhisperKitService.stagingDirectory(forModelFolder: folder))
    }
}

// MARK: - Whisper tokenizer lookup

struct WhisperTokenizerFilesTests {

    @Test func dimensionsSelectTheTokenizerRepository() {
        // Multilingual models, by encoder width
        #expect(WhisperTokenizerFiles.repoId(vocabularySize: 51865, encoderDimension: 384) == "openai/whisper-tiny")
        #expect(WhisperTokenizerFiles.repoId(vocabularySize: 51865, encoderDimension: 512) == "openai/whisper-base")
        #expect(WhisperTokenizerFiles.repoId(vocabularySize: 51865, encoderDimension: 768) == "openai/whisper-small")
        #expect(WhisperTokenizerFiles.repoId(vocabularySize: 51865, encoderDimension: 1024) == "openai/whisper-medium")
        #expect(WhisperTokenizerFiles.repoId(vocabularySize: 51865, encoderDimension: 1280) == "openai/whisper-large-v2")
        // large-v3 is recognised by its vocabulary alone
        #expect(WhisperTokenizerFiles.repoId(vocabularySize: 51866, encoderDimension: 1280) == "openai/whisper-large-v3")
        // English-only
        #expect(WhisperTokenizerFiles.repoId(vocabularySize: 51864, encoderDimension: 768) == "openai/whisper-small.en")
        // Unknown shapes fall back the way WhisperKit does
        #expect(WhisperTokenizerFiles.repoId(vocabularySize: 12345, encoderDimension: 768) == "openai/whisper-base")
    }

    @Test func readsTheDimensionsFromTheModelFoldersConfig() throws {
        let scratch = try ScratchDirectory()
        #expect(WhisperTokenizerFiles.repoId(forModelFolder: scratch.url) == nil)

        try scratch.touch("config.json", contents: #"{"d_model": 768, "vocab_size": 51865, "model_type": "whisper"}"#)
        #expect(WhisperTokenizerFiles.repoId(forModelFolder: scratch.url) == "openai/whisper-small")

        try scratch.touch("config.json", contents: #"{"model_type": "whisper"}"#)
        #expect(WhisperTokenizerFiles.repoId(forModelFolder: scratch.url) == nil)
    }

    @Test func aTokenizerIsLocalOnlyWhereWhisperKitWouldLoadIt() throws {
        let scratch = try ScratchDirectory()
        let base = scratch.url.appendingPathComponent("HuggingFace")
        let model = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let repoId = "openai/whisper-small"

        func localFolder() -> URL? {
            WhisperTokenizerFiles.localFolder(repoId: repoId, tokenizerBase: base, modelFolder: model)
        }

        // A freshly downloaded model: nothing on disk, the load would go to the Hub
        #expect(localFolder() == nil)

        // The tokenizer of another model does not count
        try scratch.touch("HuggingFace/models/openai/whisper-base/tokenizer.json")
        try scratch.touch("HuggingFace/models/openai/whisper-base/tokenizer_config.json")
        #expect(localFolder() == nil)

        // tokenizer.json alone is found but cannot be loaded: still the Hub
        try scratch.touch("HuggingFace/models/openai/whisper-small/tokenizer.json")
        #expect(localFolder() == nil)

        // Both files where WhisperKit caches them: local
        try scratch.touch("HuggingFace/models/openai/whisper-small/tokenizer_config.json")
        #expect(localFolder()?.standardizedFileURL.path
                == base.appendingPathComponent("models/openai/whisper-small").standardizedFileURL.path)
    }

    @Test func aTokenizerBundledWithTheModelCounts() throws {
        let scratch = try ScratchDirectory()
        let base = scratch.url.appendingPathComponent("HuggingFace")
        try scratch.touch("HuggingFace/models/repo/variant/tokenizer.json")
        try scratch.touch("HuggingFace/models/repo/variant/tokenizer_config.json")
        let model = base.appendingPathComponent("models/repo/variant")

        let found = WhisperTokenizerFiles.localFolder(repoId: "openai/whisper-small", tokenizerBase: base, modelFolder: model)
        #expect(found?.standardizedFileURL.path == model.standardizedFileURL.path)
    }

    @Test func anEarlierSearchPathWithoutItsConfigHidesALaterCompleteOne() throws {
        // WhisperKit stops at the first tokenizer.json; if that folder cannot
        // be loaded it does not try the next one, it downloads.
        let scratch = try ScratchDirectory()
        let base = scratch.url.appendingPathComponent("HuggingFace")
        try scratch.touch("HuggingFace/models/openai/whisper-small/tokenizer.json")
        try scratch.touch("HuggingFace/models/repo/variant/tokenizer.json")
        try scratch.touch("HuggingFace/models/repo/variant/tokenizer_config.json")
        let model = base.appendingPathComponent("models/repo/variant")

        #expect(WhisperTokenizerFiles.localFolder(repoId: "openai/whisper-small", tokenizerBase: base, modelFolder: model) == nil)
    }
}

// MARK: - Transcription language

struct TranscriptionLanguageTests {

    @Test func singleLanguageFineTunesAnswerAutoThemselves() {
        for modelId in ModelManager.kbModels {
            #expect(WhisperKitService.languageChoice(requested: nil, modelId: modelId) == .fixed("sv"))
            #expect(WhisperKitService.languageChoice(requested: "auto", modelId: modelId) == .fixed("sv"))
        }
        for modelId in ModelManager.nbModels {
            #expect(WhisperKitService.languageChoice(requested: nil, modelId: modelId) == .fixed("no"))
            #expect(WhisperKitService.languageChoice(requested: "auto", modelId: modelId) == .fixed("no"))
        }
    }

    @Test func multilingualModelsDetectInsteadOfDefaultingToEnglish() {
        for modelId in ModelManager.openAIModels {
            #expect(WhisperKitService.languageChoice(requested: nil, modelId: modelId) == .detectFromAudio)
            #expect(WhisperKitService.languageChoice(requested: "auto", modelId: modelId) == .detectFromAudio)
            #expect(WhisperKitService.languageChoice(requested: "", modelId: modelId) == .detectFromAudio)
        }
    }

    @Test func anExplicitLanguageAlwaysWins() {
        #expect(WhisperKitService.languageChoice(requested: "en", modelId: "kb_whisper-small-coreml") == .fixed("en"))
        #expect(WhisperKitService.languageChoice(requested: "sv", modelId: "nb_whisper-large-coreml") == .fixed("sv"))
        #expect(WhisperKitService.languageChoice(requested: "fi", modelId: "openai_whisper-large-v3") == .fixed("fi"))
    }
}

// MARK: - Live text while transcribing

struct StreamingCallbackStateTests {

    /// A state object plus a way to read back everything it yielded.
    private struct Harness {
        let state: StreamingCallbackState
        private let stream: AsyncThrowingStream<TranscriptionUpdate, Error>
        private let continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation

        init() {
            (stream, continuation) = AsyncThrowingStream<TranscriptionUpdate, Error>.makeStream()
            state = StreamingCallbackState(continuation: continuation)
        }

        func yielded() async throws -> [TranscriptionUpdate] {
            continuation.finish()
            var updates: [TranscriptionUpdate] = []
            for try await update in stream { updates.append(update) }
            return updates
        }
    }

    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    /// A time far enough after `start` for the n-th update to pass the throttle.
    private func time(_ n: Int) -> Date { start.addingTimeInterval(Double(n)) }

    @Test func nothingIsYieldedUntilThereIsText() async throws {
        let harness = Harness()
        // The prefill iterations report an empty text
        harness.state.update(windowId: 0, tokenCount: 4, text: "", now: time(0))
        harness.state.update(windowId: 0, tokenCount: 4, text: " ", now: time(1))
        #expect(try await harness.yielded().isEmpty)
    }

    @Test func contentUpdatesStayInTheContentBand() async throws {
        let harness = Harness()
        harness.state.update(windowId: 0, tokenCount: 5, text: " Hej", now: time(0))
        harness.state.update(windowId: 0, tokenCount: 6, text: " Hej där", now: time(1))
        let updates = try await harness.yielded()
        #expect(updates.map(\.text) == ["Hej", "Hej där"])
        #expect(updates.allSatisfy { $0.progress >= TranscriptionUpdate.contentProgressFloor && $0.progress < 1 })
        #expect(updates.allSatisfy { !$0.isComplete })
    }

    @Test func aReportOvertakenByANewerOneIsIgnored() async throws {
        let harness = Harness()
        harness.state.update(windowId: 0, tokenCount: 10, text: " ett två tre fyra fem sex", now: time(0))
        // Arrives late: the detached callback for the previous token
        harness.state.update(windowId: 0, tokenCount: 9, text: " ett två tre fyra fem", now: time(1))
        harness.state.update(windowId: 0, tokenCount: 11, text: " ett två tre fyra fem sex sju", now: time(2))
        let texts = try await harness.yielded().map(\.text)
        #expect(texts == ["ett två tre fyra fem sex", "ett två tre fyra fem sex sju"])
    }

    @Test func aStragglerFromAnEarlierWindowDoesNotReplaceTheCurrentOne() async throws {
        let harness = Harness()
        harness.state.update(windowId: 0, tokenCount: 8, text: " första fönstret", now: time(0))
        harness.state.update(windowId: 1, tokenCount: 5, text: " andra", now: time(1))
        harness.state.update(windowId: 0, tokenCount: 9, text: " första fönstret igen", now: time(2))
        harness.state.update(windowId: 1, tokenCount: 6, text: " andra fönstret", now: time(3))
        let texts = try await harness.yielded().map(\.text)
        #expect(texts == ["första fönstret", "första fönstret andra", "första fönstret andra fönstret"])
    }

    @Test func aWindowDecodedAgainFromTheStartIsAccepted() async throws {
        // A temperature fallback restarts the window: far fewer tokens, and
        // newer than what was shown — not an old report to discard.
        let harness = Harness()
        let looping = String(repeating: " och", count: 60)
        harness.state.update(windowId: 0, tokenCount: 64, text: looping, now: time(0))
        harness.state.update(windowId: 0, tokenCount: 6, text: " och sedan", now: time(1))
        let texts = try await harness.yielded().map(\.text)
        #expect(texts.last == "och sedan")
    }

    @Test func updatesAreSpacedByTheInterval() async throws {
        let harness = Harness()
        // Three steps fall short of the interval, four exceed it
        let step = StreamingCallbackState.updateInterval * 0.3
        for token in 0..<40 {
            let text = (0...token).map { "ord\($0)" }.joined(separator: " ")
            harness.state.update(windowId: 0, tokenCount: 5 + token, text: text, now: start.addingTimeInterval(Double(token) * step))
        }
        let updates = try await harness.yielded()
        // One report in four gets through, not one per token
        #expect(updates.count == 10)
        // ...and each is the newest text at the time, never an older one
        let lengths = updates.map(\.text.count)
        #expect(lengths == lengths.sorted())
    }

    @Test func unchangedTextIsNotYieldedAgain() async throws {
        let harness = Harness()
        harness.state.update(windowId: 0, tokenCount: 5, text: " Hej", now: time(0))
        // A new window whose first reports have no text yet
        harness.state.update(windowId: 1, tokenCount: 4, text: "", now: time(1))
        harness.state.update(windowId: 1, tokenCount: 4, text: "", now: time(2))
        #expect(try await harness.yielded().map(\.text) == ["Hej"])
    }

    @Test func progressFollowsThePositionOfTheChunkBeingDecoded() async throws {
        let harness = Harness()
        // Four chunks of 25 s each
        let chunk = 16_000 * 25
        harness.state.setChunkLayout(offsets: [0, chunk, 2 * chunk, 3 * chunk], lengths: [chunk, chunk, chunk, chunk])
        for window in 0..<4 {
            harness.state.update(windowId: window, tokenCount: 6, text: " del \(window)", now: time(window))
        }
        let progress = try await harness.yielded().map(\.progress)
        let floor = TranscriptionUpdate.contentProgressFloor
        #expect(progress.count == 4)
        #expect(progress[0] == floor)
        #expect(abs(progress[2] - (floor + (0.95 - floor) * 0.5)) < 0.0001)
        #expect(progress == progress.sorted())
        #expect(progress.allSatisfy { $0 < 0.95 })
    }

    @Test func nothingFollowsTheEndOfTheRun() async throws {
        let harness = Harness()
        harness.state.update(windowId: 0, tokenCount: 5, text: " Hej", now: time(0))
        harness.state.finish()
        // Callbacks are detached tasks and can still be running
        harness.state.update(windowId: 0, tokenCount: 6, text: " Hej där", now: time(1))
        #expect(try await harness.yielded().map(\.text) == ["Hej"])
    }

    @Test func survivesReportsFromManyThreadsAtOnce() async throws {
        // WhisperKit reports from a detached task per token, and the run's
        // own task reads the state while they are still coming in. Unguarded,
        // this corrupts the strings being built.
        let harness = Harness()
        let state = harness.state
        let base = start
        await withTaskGroup(of: Void.self) { group in
            for window in 0..<40 {
                for token in 0..<50 {
                    group.addTask {
                        let text = String(repeating: "x", count: token + 1)
                        state.update(windowId: window, tokenCount: token, text: text,
                                     now: base.addingTimeInterval(Double(window * 50 + token)))
                    }
                }
                group.addTask { _ = state.chunkFailure }
            }
        }
        state.finish()
        let updates = try await harness.yielded()
        #expect(!updates.isEmpty)
        #expect(updates.allSatisfy { update in update.text.allSatisfy { $0 == "x" || $0 == " " } })
    }

    @Test func aFailedChunkIsReported() {
        struct ChunkError: Error {}
        let harness = Harness()
        #expect(harness.state.chunkFailure == nil)

        harness.state.recordChunkResults([Result<Int, Error>.success(1), .failure(CancellationError()), .failure(ChunkError())])
        let failure = harness.state.chunkFailure
        #expect(failure?.failedChunks == 2)
        #expect(failure?.chunkCount == 3)
        // The real failure, not the cancellation that happened to come first
        #expect(failure?.error is ChunkError)
    }

    @Test func chunksThatOnlyFailedByCancellationAreStillNotASuccess() {
        let harness = Harness()
        harness.state.recordChunkResults([Result<Int, Error>.success(1), .failure(CancellationError())])
        #expect(harness.state.chunkFailure?.error is CancellationError)
    }

    @Test func aRunWhoseChunksAllFailIsNotAnEmptySuccess() async throws {
        // A WhisperKit without a model: every chunk fails as soon as it is
        // picked up. Upstream answers that with an empty result and no error.
        let kit = try await TranscribeWhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        let harness = Harness()
        let silence = [Float](repeating: 0, count: 16_000 * 70)

        let results = try await StreamingCallbackState.$current.withValue(harness.state) {
            try await kit.transcribe(
                audioArray: silence,
                decodeOptions: DecodingOptions(concurrentWorkerCount: 1, chunkingStrategy: .vad)
            )
        }
        #expect(results.isEmpty)

        // The run saw what was dropped, which is what the service throws
        let failure = try #require(harness.state.chunkFailure)
        #expect(failure.chunkCount >= 2)
        #expect(failure.failedChunks == failure.chunkCount)
        #expect(!(failure.error is CancellationError))
    }

    @Test func chunkResultsOfAnotherTaskAreNotMixedIn() async throws {
        let kit = try await TranscribeWhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
        let harness = Harness()
        let silence = [Float](repeating: 0, count: 16_000 * 70)
        // Same failing run, but outside this harness's task-local scope
        _ = try await kit.transcribe(
            audioArray: silence,
            decodeOptions: DecodingOptions(concurrentWorkerCount: 1, chunkingStrategy: .vad)
        )
        #expect(harness.state.chunkFailure == nil)
    }
}
