import AVFoundation
import Foundation
import os
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

// MARK: - Cloud uploads: when to split

struct AudioPreprocessingTests {

    /// Writes a mono 16-bit PCM WAV with a tone in it.
    private func writeWAV(to url: URL, seconds: Double, sampleRate: Int = 16_000) throws {
        let frameCount = Int(seconds * Double(sampleRate))
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataSize = UInt32(frameCount * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                  // fmt chunk size
        append(UInt16(1))                   // PCM
        append(UInt16(1))                   // channels
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))      // byte rate
        append(UInt16(2))                   // block align
        append(UInt16(16))                  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for frame in 0..<frameCount {
            append(Int16(8_000 * sin(2 * Double.pi * 440 * Double(frame) / Double(sampleRate))))
        }
        try data.write(to: url)
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @Test func aSourceOverTheLimitThatConvertsSmallIsUploadedWhole() async throws {
        let scratch = try ScratchDirectory()
        let source = scratch.url.appendingPathComponent("recording.wav")
        try writeWAV(to: source, seconds: 12)   // 384 kB
        // The service's limits, scaled down: the source is over the upload
        // limit, its 32 kbps conversion (some 50 kB) is far below it. Chunks
        // are 4 s so that splitting, if it happened, would show.
        let preprocessor = AudioPreprocessor(maxFileSize: 150_000, chunkDuration: 4, overlapDuration: 1)

        let processed = try await preprocessor.preprocessAudio(url: source)
        defer { preprocessor.cleanupProcessedAudio(processed) }

        #expect(processed.chunks.count == 1)
        #expect(processed.url.pathExtension == "m4a")
        #expect(processed.chunks.first?.url == processed.url)
        #expect(abs((processed.chunks.first?.endTime ?? 0) - 12) < 0.5)
        #expect(abs(processed.originalDuration - 12) < 0.01)
        #expect(abs(try await duration(of: processed.url) - 12) < 0.5)
    }

    @Test func aConversionStillOverTheLimitIsSplitWithOverlap() async throws {
        let scratch = try ScratchDirectory()
        let source = scratch.url.appendingPathComponent("recording.wav")
        try writeWAV(to: source, seconds: 12)
        // No conversion of 12 s fits in 2 kB
        let preprocessor = AudioPreprocessor(maxFileSize: 2_000, chunkDuration: 4, overlapDuration: 1)

        let processed = try await preprocessor.preprocessAudio(url: source)
        #expect(processed.chunks.map(\.startTime) == [0, 3, 6, 9])
        #expect(processed.chunks.map(\.index) == [0, 1, 2, 3])
        for chunk in processed.chunks.dropLast() {
            #expect(abs(chunk.endTime - chunk.startTime - 4) < 0.001)
            #expect(abs(try await duration(of: chunk.url) - 4) < 0.5)
        }

        // Cleanup takes the temporary files and leaves the user's file alone
        let temporary = [processed.url] + processed.chunks.map(\.url)
        preprocessor.cleanupProcessedAudio(processed)
        #expect(temporary.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func aSmallNativeFileIsSentAsItIs() async throws {
        let scratch = try ScratchDirectory()
        let source = scratch.url.appendingPathComponent("recording.wav")
        try writeWAV(to: source, seconds: 2)
        let processed = try await AudioPreprocessor.shared.preprocessAudio(url: source)
        #expect(processed.url == source)
        #expect(processed.chunks.count == 1)
        #expect(!processed.needsCleanup)
    }

    @Test func extractsTheAudioOfAContainerForLocalTranscription() async throws {
        let scratch = try ScratchDirectory()
        let wav = scratch.url.appendingPathComponent("recording.wav")
        try writeWAV(to: wav, seconds: 3)
        // An MPEG-4 container, which the local engines do not read directly:
        // the AAC conversion under the name a video file would have.
        let preprocessor = AudioPreprocessor(maxFileSize: 50_000)
        let converted = try await preprocessor.preprocessAudio(url: wav)
        defer { preprocessor.cleanupProcessedAudio(converted) }
        let container = scratch.url.appendingPathComponent("recording.mp4")
        try FileManager.default.copyItem(at: converted.url, to: container)
        #expect(AudioPreprocessor.shared.needsConversionForWhisperKit(url: container))

        let extracted = try await AudioPreprocessor.shared.extractAudioForWhisperKit(url: container)
        defer { try? FileManager.default.removeItem(at: extracted) }
        #expect(extracted.pathExtension == "wav")
        #expect(abs(try await duration(of: extracted) - 3) < 0.2)
    }
}

// MARK: - Cloud uploads: joining chunks

struct ChunkOverlapTests {

    /// "ord0 ord1 …": distinct words, so every repetition is unambiguous.
    private func text(_ range: Range<Int>) -> String {
        range.map { "ord\($0)" }.joined(separator: " ")
    }

    // 30 s of overlap is 60 to 100 words of ordinary speech; the search used
    // to stop after 50.
    @Test(arguments: [8, 50, 51, 75, 110, 150])
    func removesAnOverlapOfRealisticLength(overlapWords: Int) {
        let previous = text(0..<400)
        let current = text((400 - overlapWords)..<600)
        let remainder = AudioPreprocessor.removeOverlap(previousText: previous, currentText: current, overlapDuration: 30)
        #expect(remainder == text(400..<600))
    }

    @Test func theSeamHasNoRepeatedWord() {
        // The match used to be returned from its last word, so that word
        // appeared on both sides of every seam.
        let previous = text(0..<100)
        let current = text(90..<120)
        let remainder = AudioPreprocessor.removeOverlap(previousText: previous, currentText: current, overlapDuration: 30)
        #expect(remainder.split(separator: " ").first == "ord100")
    }

    @Test func textWithoutAnOverlapIsKeptWhole() {
        let previous = text(0..<200)
        let current = text(500..<700)
        #expect(AudioPreprocessor.removeOverlap(previousText: previous, currentText: current, overlapDuration: 30) == current)
        #expect(AudioPreprocessor.removeOverlap(previousText: "", currentText: current, overlapDuration: 30) == current)
    }

    @Test func aFewWordsInCommonAreNotAnOverlap() {
        let previous = text(0..<200)
        // The last three words of the previous text happen to recur
        let current = text(300..<320) + " " + text(197..<200) + " " + text(320..<340)
        #expect(AudioPreprocessor.removeOverlap(previousText: previous, currentText: current, overlapDuration: 30) == current)
    }

    @Test func aChunkThatOnlyRepeatsLeavesNothing() {
        let previous = text(0..<200)
        #expect(AudioPreprocessor.removeOverlap(previousText: previous, currentText: text(150..<200), overlapDuration: 30).isEmpty)
    }
}

struct ChunkMergeTests {

    private func chunk(_ index: Int, _ start: Double, _ end: Double) -> AudioPreprocessor.AudioChunk {
        AudioPreprocessor.AudioChunk(url: URL(fileURLWithPath: "/chunk\(index).m4a"), startTime: start, endTime: end, index: index)
    }

    private func result(_ segments: [TranscriptionSegment], text: String = "") -> TranscriptionResult {
        TranscriptionResult(text: text, segments: segments, language: "sv", duration: 0, timestamp: Date(), modelUsed: "test")
    }

    private func segment(_ start: Double, _ end: Double, _ text: String, words: [(String, Double, Double)]? = nil) -> TranscriptionSegment {
        TranscriptionSegment(
            id: 0, start: start, end: end, text: text, confidence: nil, speaker: "SPEAKER_00",
            words: words?.map { TranscriptionWord(word: $0.0, start: $0.1, end: $0.2, speaker: "SPEAKER_00") }
        )
    }

    /// Chunk times as the preprocessor makes them: 9 minutes, 30 s overlap.
    private var firstChunk: AudioPreprocessor.AudioChunk { chunk(0, 0, 540) }
    private var secondChunk: AudioPreprocessor.AudioChunk { chunk(1, 510, 1050) }

    @Test func aSegmentAcrossTheEndOfTheOverlapIsCutNotDropped() {
        let first = result([
            segment(520, 530, "detta är slutet på första delen"),
            segment(530, 539.8, "och här tar den slut"),
        ])
        let second = result([
            // Entirely inside the overlap: the first chunk has it
            segment(10, 20, "detta är slutet på första delen"),
            // Starts in the overlap (which ends at 30 s), ends after it
            segment(20, 33, "och här tar den slut nu börjar andra delen", words: [
                ("och", 20.0, 20.4), ("här", 20.5, 20.9), ("tar", 21.0, 21.4), ("den", 21.5, 21.9), ("slut", 29.2, 29.8),
                ("nu", 29.9, 30.3), ("börjar", 30.4, 31.0), ("andra", 31.1, 31.6), ("delen", 31.7, 32.5),
            ]),
            segment(40, 45, "som fortsätter", words: [("som", 40.0, 40.5), ("fortsätter", 40.6, 45.0)]),
        ])

        let merged = AudioPreprocessor.shared.mergeChunkedTranscriptions([(firstChunk, first), (secondChunk, second)])

        #expect(merged.segments.map(\.text) == [
            "detta är slutet på första delen",
            "och här tar den slut",
            "nu börjar andra delen",
            "som fortsätter",
        ])
        // Text and segments say the same thing
        #expect(merged.text == merged.segments.map(\.text).joined(separator: " "))
        #expect(merged.segments.map(\.id) == [0, 1, 2, 3])

        // The cut segment starts at its first kept word, on the file's timeline
        let cut = merged.segments[2]
        #expect(abs(cut.start - 539.9) < 0.0001)
        #expect(abs(cut.end - 543) < 0.0001)
        #expect(cut.words?.map(\.word) == ["nu", "börjar", "andra", "delen"])
        #expect(abs((cut.words?.first?.start ?? 0) - 539.9) < 0.0001)

        // Word timings survive the merge, shifted to the file's timeline
        let last = merged.segments[3]
        #expect(last.words?.map(\.start) == [550.0, 550.6])
        #expect(last.words?.last?.end == 555.0)
        #expect(last.words?.first?.speaker == "SPEAKER_00")
    }

    @Test func aSegmentWithoutWordTimingsLosesOnlyTheWordsItRepeats() {
        let first = result([segment(525, 539.5, "ett två tre fyra fem sex sju")])
        let second = result([segment(15, 34, "ett två tre fyra fem sex sju åtta nio")])

        let merged = AudioPreprocessor.shared.mergeChunkedTranscriptions([(firstChunk, first), (secondChunk, second)])

        #expect(merged.segments.map(\.text) == ["ett två tre fyra fem sex sju", "åtta nio"])
        #expect(merged.text == "ett två tre fyra fem sex sju åtta nio")
        #expect(merged.segments[1].start == 540)
        #expect(merged.segments[1].end == 544)
    }

    @Test func nothingIsCutFromAChunkWhosePredecessorIsMissing() {
        // The middle chunk failed; the third one's first 30 s are not in any
        // other transcription.
        let first = result([segment(0, 10, "första")])
        let third = result([segment(5, 15, "börjar mitt i"), segment(40, 50, "och fortsätter")])

        let merged = AudioPreprocessor.shared.mergeChunkedTranscriptions([(firstChunk, first), (chunk(2, 1020, 1560), third)])

        #expect(merged.segments.map(\.text) == ["första", "börjar mitt i", "och fortsätter"])
        #expect(merged.segments[1].start == 1025)
    }

    @Test func resultsWithoutSegmentsAreJoinedByTheirText() {
        let words = { (range: Range<Int>) in range.map { "ord\($0)" }.joined(separator: " ") }
        let first = result([], text: words(0..<400))
        let second = result([], text: words(320..<600))

        let merged = AudioPreprocessor.shared.mergeChunkedTranscriptions([(firstChunk, first), (secondChunk, second)])

        #expect(merged.text == words(0..<600))
        #expect(merged.segments.isEmpty)
    }

    @Test func nothingToMergeGivesAnEmptyResult() {
        let merged = AudioPreprocessor.shared.mergeChunkedTranscriptions([])
        #expect(merged.text.isEmpty)
        #expect(merged.segments.isEmpty)
    }
}

// MARK: - Cloud transcription

struct BergetResponseTests {

    @Test func aWordWithoutTimingIsKeptAtItsNeighboursTime() {
        // The aligner cannot place numerals; they come back without start/end
        let words = BergetTranscriptionService.words(from: [
            ["word": "Det", "start": 1.0, "end": 1.2, "speaker": "SPEAKER_01"],
            ["word": "kostar", "start": 1.2, "end": 1.6, "speaker": "SPEAKER_01"],
            ["word": "250"],
            ["word": "kronor", "start": 2.0, "end": 2.4, "speaker": "SPEAKER_01"],
        ], segmentStart: 1.0)

        #expect(words.map(\.word) == ["Det", "kostar", "250", "kronor"])
        #expect(words[2].start == 1.6)
        #expect(words[2].end == 1.6)
        #expect(words[2].speaker == nil)
        #expect(words[3].start == 2.0)
    }

    @Test func untimedWordsAtTheStartTakeTheNextTimedWord() {
        let words = BergetTranscriptionService.words(from: [
            ["word": "3"],
            ["word": "%"],
            ["word": "ränta", "start": 5.0, "end": 5.5],
        ], segmentStart: 4.0)
        #expect(words.map(\.start) == [5.0, 5.0, 5.0])
        #expect(words.map(\.end) == [5.0, 5.0, 5.5])
    }

    @Test func aSegmentOfOnlyUntimedWordsUsesItsOwnStart() {
        let words = BergetTranscriptionService.words(from: [["word": "2024"], ["word": "2025"]], segmentStart: 12.5)
        #expect(words.map(\.word) == ["2024", "2025"])
        #expect(words.allSatisfy { $0.start == 12.5 && $0.end == 12.5 })
    }

    @Test func readsNestedAndFlatSegmentLists() {
        let segment: [String: Any] = [
            "start": 0.0, "end": 2.5, "speaker": "SPEAKER_00", "text": " Klockan är 12 ",
            "words": [
                ["word": "Klockan", "start": 0.1, "end": 0.6],
                ["word": "är", "start": 0.7, "end": 0.9],
                ["word": "12"],
            ],
        ]
        let nested = BergetTranscriptionService.segments(fromResponse: ["text": "x", "segments": ["segments": [segment]]])
        let flat = BergetTranscriptionService.segments(fromResponse: ["text": "x", "segments": [segment]])

        for segments in [nested, flat] {
            #expect(segments.count == 1)
            #expect(segments.first?.text == "Klockan är 12")
            #expect(segments.first?.speaker == "SPEAKER_00")
            #expect(segments.first?.words?.map(\.word) == ["Klockan", "är", "12"])
        }
        #expect(BergetTranscriptionService.segments(fromResponse: ["text": "x"]).isEmpty)
    }
}

struct BergetCancellationTests {
    /// A file that does not exist: the request fails while it is being put
    /// together, before anything is sent.
    private let missingFile = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")

    @Test func theCallbackVariantReportsItsOutcome() async {
        let service = BergetTranscriptionService(apiKey: "test")
        let result = await withCheckedContinuation { continuation in
            service.transcribe(audioURL: missingFile) { result in
                continuation.resume(returning: result)
            }
        }
        #expect(throws: (any Error).self) { try result.get() }
    }

    @Test @MainActor func nothingIsReportedAfterCancel() async throws {
        let service = BergetTranscriptionService(apiKey: "test")
        let reported = OSAllocatedUnfairLock(initialState: false)
        service.transcribe(audioURL: missingFile) { _ in
            reported.withLock { $0 = true }
        }
        // Completion handlers run on the main actor, which this test holds
        // until it suspends: the cancel is certain to come first.
        service.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!reported.withLock { $0 })
    }

    @Test func cancellingTheCallingTaskThrowsCancellationError() async {
        let service = BergetTranscriptionService(apiKey: "test")
        let file = missingFile
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.transcribe(audioURL: file)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
