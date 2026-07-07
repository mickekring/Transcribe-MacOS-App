import Foundation
import os

/// A model as served by Berget's /v1/models endpoint.
struct BergetModel: Codable, Identifiable, Equatable {
    let id: String              // API id, e.g. "KBLab/kb-whisper-large"
    let name: String            // short name, e.g. "kb-whisper-large"
    let modelType: String       // "text" | "speech-to-text" | "embedding" | "rerank"
    let lifecycleState: String  // "stable" | "eval" | "maintenance"
    let isUp: Bool

    var isStable: Bool { lifecycleState == "stable" }
}

/// Live catalog of Berget's available models, replacing hardcoded registries.
/// Fetched from /v1/models (which carries type, lifecycle state, and up/down
/// status per model) and cached in UserDefaults so the pickers keep working
/// offline with the last known state.
@MainActor
final class BergetModelCatalog: ObservableObject {
    static let shared = BergetModelCatalog()

    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "BergetCatalog")
    private static let cacheKey = "bergetModelCatalogCache"

    @Published private(set) var models: [BergetModel] = []
    private var isRefreshing = false

    /// Chat models currently serving (down/maintenance models are hidden).
    var llmModels: [BergetModel] {
        models.filter { $0.modelType == "text" && $0.isUp }
    }

    /// Speech-to-text models currently serving.
    var asrModels: [BergetModel] {
        models.filter { $0.modelType == "speech-to-text" && $0.isUp }
    }

    private init() {
        loadCache()
    }

    /// Fetches the current model list. Safe to call often; concurrent calls
    /// coalesce and failures keep the cached list.
    func refresh(apiKey: String) async {
        guard !apiKey.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var request = URLRequest(url: URL(string: "https://api.berget.ai/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                logger.warning("Model catalog fetch failed with status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]] else {
                logger.warning("Model catalog response had unexpected shape")
                return
            }

            let parsed: [BergetModel] = list.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return BergetModel(
                    id: id,
                    name: entry["name"] as? String ?? id.components(separatedBy: "/").last ?? id,
                    modelType: entry["model_type"] as? String ?? "unknown",
                    lifecycleState: entry["lifecycle_state"] as? String ?? "unknown",
                    isUp: ((entry["status"] as? [String: Any])?["up"] as? Bool) ?? true
                )
            }

            guard !parsed.isEmpty else { return }
            models = parsed
            saveCache()
            logger.info("Model catalog refreshed: \(parsed.count) models (\(self.llmModels.count) LLMs, \(self.asrModels.count) ASR)")
        } catch {
            // Offline or API down — the cached list stays in effect
            logger.warning("Model catalog fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode([BergetModel].self, from: data) else { return }
        models = cached
    }
}
