import Foundation
import SwiftUI
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import TranscribeKit

/// The on-device LLMs the app offers. Selection is stored in
/// @AppStorage("iosSelectedLLM") as "e2b"/"e4b" for local models and
/// "berget:<api-id>" for cloud models — same scheme as transcription models.
struct LocalLLMModel: Identifiable {
    let id: String
    let repo: String
    let name: String
    let sizeLabel: String

    static let all = [
        LocalLLMModel(id: "e2b", repo: "mlx-community/gemma-4-e2b-it-4bit",
                      name: "Gemma 4 E2B", sizeLabel: "1,5 GB"),
        LocalLLMModel(id: "e4b", repo: "mlx-community/gemma-4-e4b-it-4bit",
                      name: "Gemma 4 E4B", sizeLabel: "4,5 GB")
    ]

    static func byId(_ id: String) -> LocalLLMModel? {
        all.first { $0.id == id }
    }

    var isDownloaded: Bool {
        Self.snapshotDirectory(repo: repo) != nil
    }

    /// Locates a downloaded snapshot under Documents/huggingface (where the
    /// hub client stores weights) by repo name + safetensors presence.
    static func snapshotDirectory(repo: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs.appendingPathComponent("huggingface")
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        let repoName = repo.components(separatedBy: "/").last ?? repo
        for case let url as URL in enumerator {
            if url.lastPathComponent == repoName,
               let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
               contents.contains(where: { $0.hasSuffix(".safetensors") }) {
                return url
            }
        }
        return nil
    }

    func delete() {
        if let dir = Self.snapshotDirectory(repo: repo) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

/// Holds the loaded MLX model for the app session so repeat runs are instant.
@MainActor
enum LLMRuntime {
    private(set) static var container: ModelContainer?
    private(set) static var loadedRepo: String?

    /// Loads (downloading first if needed) the given repo, reusing the
    /// resident container when it matches.
    static func loadContainer(repo: String,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> ModelContainer {
        if let container, loadedRepo == repo { return container }
        release()
        // E4B (~4.5 GB) plus a resident Whisper model overflows the ~6 GB
        // per-app budget — free Whisper first; it reloads on next use.
        if repo.contains("e4b") {
            WhisperKitService.shared.unloadModel()
        }
        let loaded = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: repo)
        ) { p in
            progress(p.fractionCompleted)
        }
        container = loaded
        loadedRepo = repo
        return loaded
    }

    static func release() {
        container = nil
        loadedRepo = nil
    }
}
