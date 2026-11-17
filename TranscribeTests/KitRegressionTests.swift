import Foundation
import Testing
@testable import TranscribeKit

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
