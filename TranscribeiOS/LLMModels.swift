import Foundation
import SwiftUI
import MLX
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
    let shortName: String
    let sizeLabel: String

    // E4B is an experiment against the ~6 GB per-app ceiling: its 4-bit
    // weights are 5.15 GB on disk, but like E2B it's a PLE architecture
    // (per-layer embeddings stream from storage), so resident memory should
    // land well below file size — E2B runs at 2.87 GB against a 3.55 GB
    // file. It crashed under the old memory regime; retrying with the
    // Whisper swap, 64 MB cache limit, and 8-bit KV in place.
    static let all = [
        LocalLLMModel(id: "e2b", repo: "mlx-community/gemma-4-e2b-it-4bit",
                      name: "Gemma 4 E2B", shortName: "Gemma E2B", sizeLabel: "3,6 GB"),
        LocalLLMModel(id: "e4b", repo: "mlx-community/gemma-4-e4b-it-4bit",
                      name: "Gemma 4 E4B", shortName: "Gemma E4B", sizeLabel: "5,2 GB"),
        LocalLLMModel(id: "qwen4b", repo: "mlx-community/Qwen3.5-4B-4bit",
                      name: "Qwen 3.5 4B", shortName: "Qwen 4B", sizeLabel: "3,1 GB")
    ]

    static func byId(_ id: String) -> LocalLLMModel? {
        all.first { $0.id == id }
    }
}

/// Downloads and tracks on-device LLM weights. A singleton so downloads
/// survive navigation — start one, go transcribe something, the progress
/// is still here when you come back.
///
/// The hub client stores snapshots under Library/Caches/huggingface/hub
/// in HF hub layout (models--org--repo/…); TranscribeiOSApp relocates that
/// directory into Application Support behind a symlink so iOS storage
/// purges can't silently evict gigabytes of weights.
@MainActor
final class LLMDownloadManager: ObservableObject {
    static let shared = LLMDownloadManager()

    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var downloaded: Set<String> = []

    private init() {
        refresh()
    }

    nonisolated static var hubRootDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
            .resolvingSymlinksInPath()
    }

    /// The repo's snapshot directory in HF hub-cache layout, or nil if not
    /// present. Checks the standard hub/ location first, then searches the
    /// whole huggingface root in case the client's layout differs.
    nonisolated static func snapshotDir(repo: String) -> URL? {
        let fm = FileManager.default
        let dirName = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let standard = hubRootDir.appendingPathComponent("hub").appendingPathComponent(dirName)
        if fm.fileExists(atPath: standard.path) { return standard }
        if let enumerator = fm.enumerator(at: hubRootDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator where url.lastPathComponent == dirName {
                return url
            }
        }
        return nil
    }

    nonisolated static func hasSnapshot(repo: String) -> Bool {
        guard let dir = snapshotDir(repo: repo),
              let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "safetensors" {
            return true
        }
        return false
    }

    func refresh() {
        downloaded = Set(LocalLLMModel.all
            .filter { Self.hasSnapshot(repo: $0.repo) }
            .map(\.id))
    }

    func download(_ model: LocalLLMModel) {
        guard progress[model.id] == nil else { return }
        progress[model.id] = 0
        Task {
            do {
                // Download-only: no model loading, no memory spike
                let client = HubClient()
                _ = try await client.downloadSnapshot(of: Repo.ID(stringLiteral: model.repo), kind: .model) { p in
                    Task { @MainActor in
                        LLMDownloadManager.shared.progress[model.id] = p.fractionCompleted
                    }
                }
            } catch {
                // Row falls back to the download button
            }
            progress[model.id] = nil
            refresh()
        }
    }

    func delete(_ model: LocalLLMModel) {
        if let dir = Self.snapshotDir(repo: model.repo) {
            try? FileManager.default.removeItem(at: dir)
        }
        LLMRuntime.release()
        refresh()
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
        // E2B's weights are 3.55 GB; together with a resident Whisper model
        // that crowds the ~6 GB per-app budget — free Whisper first, it
        // reloads on the next transcription.
        WhisperKitService.shared.unloadModel()
        // Without a cache limit MLX parks every intermediate buffer from
        // prompt processing in its Metal cache — on a long transcript that
        // alone grows by gigabytes. 64 MB keeps generation fast while
        // returning the rest to the OS.
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
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
        // Dropping the container returns buffers to MLX's Metal cache, not
        // to the OS — without this the app's footprint stays ~3.5 GB and
        // the next Whisper load gets jetsammed.
        MLX.Memory.clearCache()
    }
}
