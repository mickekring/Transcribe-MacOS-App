import ArgmaxCore
import Foundation
import Testing
import os
@testable import TranscribeKit

/// End-to-end check of the WhisperKit path against a real model, alongside
/// the Parakeet ones. It guards package updates: WhisperKit and the
/// tokenizer it decodes with both shape the final text.
///
/// Opt-in like `ParakeetIntegrationTests` (`RUN_MODEL_TESTS=1`). It uses
/// KB Whisper Small and skips if that model is not downloaded, rather than
/// fetching half a gigabyte.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1", "set RUN_MODEL_TESTS=1 to run"),
    .serialized,
    .timeLimit(.minutes(10))
)
@MainActor
struct WhisperIntegrationTests {
    private static let log = Logger(subsystem: "com.mickekring.transcribe.tests", category: "integration")
    nonisolated private static let model = "kb_whisper-small-coreml"

    @Test(.enabled(if: ModelManager.shared.isModelDownloaded(model), "KB Whisper Small is not downloaded"))
    func kbWhisperTranscribesSwedishSpeech() async throws {
        let fixture = try await SpeechFixture.make(text: ParakeetIntegrationTests.swedish, language: "sv-SE")
        defer { fixture.remove() }

        var final: TranscriptionUpdate?
        for try await update in WhisperKitService.shared.transcribe(fileURL: fixture.url, modelId: Self.model, language: "auto") {
            if update.isComplete { final = update }
        }
        let result = try #require(final)
        let wer = ParakeetIntegrationTests.wordErrorRate(reference: ParakeetIntegrationTests.swedish, hypothesis: result.text)
        Self.log.notice("WHISPER kb-small (WER \(wer, format: .fixed(precision: 3)), \(result.segments.count) segments): \(result.text, privacy: .public)")

        // "Auto" on a Swedish fine-tune must decode as Swedish
        #expect(wer < 0.2, "word error rate \(wer)")
        for word in ["budgeten", "göteborg", "sommarfesten"] {
            #expect(result.text.lowercased().contains(word), "missing \(word)")
        }
        #expect(!result.segments.isEmpty)
        // No doubled spaces or space before punctuation in the final text
        #expect(!result.text.contains("  "))
        #expect(result.text.range(of: #" [.,?!]"#, options: .regularExpression) == nil, "space before punctuation")
    }

    /// Every pinned commit still exists on Hugging Face and holds what the
    /// app downloads from it. Listing only, so it is quick.
    @Test func everyPinnedCommitHoldsItsModel() async throws {
        let hub = HubApiWrapper(downloadBase: FileManager.default.temporaryDirectory)
        for modelId in ModelManager.kbModels + ModelManager.nbModels + ModelManager.openAIModels {
            let repo = WhisperKitService.modelRepo(for: modelId)
            let variant = try #require(WhisperKitService.modelVariant(for: modelId))
            let files = try await hub.getFilenames(
                from: HubApiWrapper.Repo(id: repo), revision: try ModelRevisions.revision(for: repo), matching: ["\(variant)/*"]
            )
            #expect(files.contains { $0.hasPrefix("\(variant)/") && $0.hasSuffix("config.json") }, "\(modelId) at its pinned commit")
        }
        for (repo, revision) in ModelRevisions.pinned where repo.hasPrefix("openai/") {
            let files = try await hub.getFilenames(from: HubApiWrapper.Repo(id: repo), revision: revision, matching: WhisperTokenizerFiles.downloadedFiles)
            #expect(files.contains("tokenizer.json"), "\(repo) tokenizer at its pinned commit")
        }
        let speakerFiles = try await hub.getFilenames(
            from: HubApiWrapper.Repo(id: ModelRevisions.speakerKitRepo),
            revision: try ModelRevisions.revision(for: ModelRevisions.speakerKitRepo)
        )
        #expect(!speakerFiles.isEmpty)
    }

    /// The pinned download itself, into a scratch folder: the smallest
    /// model, fetched the way `WhisperKitService` fetches every model.
    @Test func aPinnedDownloadLandsInTheVariantFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let modelId = "nb_whisper-tiny-coreml"
        let repo = WhisperKitService.modelRepo(for: modelId)
        let variant = try #require(WhisperKitService.modelVariant(for: modelId))

        let repoFolder = try await HubApiWrapper(downloadBase: base).snapshot(
            from: HubApiWrapper.Repo(id: repo), revision: try ModelRevisions.revision(for: repo), matching: ["\(variant)/*"]
        )
        let folder = repoFolder.appendingPathComponent(variant)
        #expect(folder == WhisperKitService.defaultModelFolder(for: modelId, downloadBase: base))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path))
    }
}
