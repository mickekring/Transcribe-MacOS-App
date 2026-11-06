import Foundation
import SwiftUI

public class ModelManager: ObservableObject {
    nonisolated(unsafe) public static let shared = ModelManager()
    
    @Published public var downloadProgress: [String: Double] = [:]
    @Published public var downloadedModels: Set<String> = []
    @Published public var isDownloading: [String: Bool] = [:]
    @Published public var downloadSpeed: [String: Double] = [:]  // bytes/sec
    
    /// All available local model IDs
    public static let allLocalModels: [String] = [
        "kb_whisper-base-coreml",
        "kb_whisper-small-coreml",
        "kb_whisper-medium-coreml",
        "kb_whisper-large-coreml",
        "nb_whisper-tiny-coreml",
        "nb_whisper-base-coreml",
        "nb_whisper-small-coreml",
        "nb_whisper-large-coreml",
        "openai_whisper-base",
        "openai_whisper-small",
        "openai_whisper-medium",
        "openai_whisper-large-v2",
        "openai_whisper-large-v3",
        "klang_pianissimo-sv",
    ]

    public static let kbModels: [String] = allLocalModels.filter { $0.starts(with: "kb_whisper-") }
    public static let nbModels: [String] = allLocalModels.filter { $0.starts(with: "nb_whisper-") }
    public static let openAIModels: [String] = allLocalModels.filter { $0.starts(with: "openai_whisper-") }
    /// Parakeet-based models (FluidAudio runtime, not WhisperKit)
    public static let klangModels: [String] = allLocalModels.filter { $0.starts(with: "klang_") }

    private let modelSizes: [String: Int64] = [
        "kb_whisper-base-coreml": 145_000_000,
        "kb_whisper-small-coreml": 483_000_000,
        "kb_whisper-medium-coreml": 1_530_000_000,
        "kb_whisper-large-coreml": 3_090_000_000,
        "nb_whisper-tiny-coreml": 75_000_000,
        "nb_whisper-base-coreml": 145_000_000,
        "nb_whisper-small-coreml": 483_000_000,
        "nb_whisper-large-coreml": 3_090_000_000,
        "openai_whisper-base": 145_000_000,
        "openai_whisper-small": 483_000_000,
        "openai_whisper-medium": 1_530_000_000,
        "openai_whisper-large-v2": 3_090_000_000,
        "openai_whisper-large-v3": 3_090_000_000,
        "klang_pianissimo-sv": 688_000_000,
    ]

    private static let displayNames: [String: String] = [
        "kb_whisper-base-coreml": "KB Whisper Base",
        "kb_whisper-small-coreml": "KB Whisper Small",
        "kb_whisper-medium-coreml": "KB Whisper Medium",
        "kb_whisper-large-coreml": "KB Whisper Large",
        "nb_whisper-tiny-coreml": "NB Whisper Tiny",
        "nb_whisper-base-coreml": "NB Whisper Base",
        "nb_whisper-small-coreml": "NB Whisper Small",
        "nb_whisper-large-coreml": "NB Whisper Large",
        "openai_whisper-base": "Whisper Base",
        "openai_whisper-small": "Whisper Small",
        "openai_whisper-medium": "Whisper Medium",
        "openai_whisper-large-v2": "Whisper Large v2",
        "openai_whisper-large-v3": "Whisper Large v3",
        "klang_pianissimo-sv": "Klang Pianissimo",
    ]
    
    /// UserDefaults key for persisted model folder paths
    private static let modelFolderPathsKey = "whisperKitModelFolderPaths"
    
    private init() {
        createModelsDirectory()
        validateDownloadedModels()
    }
    
    // MARK: - Storage Locations
    
    /// Base directory for all app model storage.
    /// Located in Application Support so it's cleaned up when the app is deleted.
    public var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.transcribe.app"
        return appSupport.appendingPathComponent(bundleID).appendingPathComponent("Models")
    }
    
    /// The download base passed to WhisperKit/HubApi so models are stored
    /// inside Application Support instead of ~/Documents/huggingface.
    public var downloadBase: URL {
        modelsDirectory.appendingPathComponent("HuggingFace")
    }
    
    private func createModelsDirectory() {
        try? FileManager.default.createDirectory(at: downloadBase,
                                                withIntermediateDirectories: true)
    }
    
    // MARK: - Model Folder Path Tracking
    
    /// Returns the persisted local folder path for a previously downloaded model, or nil if not yet downloaded.
    public func cachedModelFolder(for modelId: String) -> String? {
        let paths = loadModelFolderPaths()
        guard let stored = paths[modelId] else { return nil }

        guard let resolved = resolveStoredPath(stored) else {
            // Model folder was deleted externally — clear the stale entry
            removeModelFolderPath(for: modelId)
            return nil
        }
        // Migrate legacy absolute entries to the container-independent form
        let relative = Self.relativeToAppSupport(resolved)
        if relative != stored {
            var updated = paths
            updated[modelId] = relative
            UserDefaults.standard.set(updated, forKey: Self.modelFolderPathsKey)
        }
        return resolved
    }

    /// Persists the local folder path after a successful model download.
    /// Stored relative to Application Support: on iOS the app's container
    /// path changes on every reinstall, so absolute paths go stale even
    /// though the files survive.
    public func saveModelFolderPath(_ path: String, for modelId: String) {
        var paths = loadModelFolderPaths()
        paths[modelId] = Self.relativeToAppSupport(path)
        UserDefaults.standard.set(paths, forKey: Self.modelFolderPathsKey)
        downloadedModels.insert(modelId)
    }

    private static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    private static func relativeToAppSupport(_ path: String) -> String {
        if let range = path.range(of: "/Application Support/") {
            return String(path[range.upperBound...])
        }
        return path
    }

    /// Resolves a stored path (relative or legacy absolute) to an existing
    /// absolute path in the current container, or nil if the folder is gone.
    private func resolveStoredPath(_ stored: String) -> String? {
        let fm = FileManager.default
        if stored.hasPrefix("/") {
            if fm.fileExists(atPath: stored) { return stored }
            // Container moved (iOS reinstall): re-base the stable suffix
            // onto the current Application Support directory.
            let rebased = Self.appSupportDir
                .appendingPathComponent(Self.relativeToAppSupport(stored)).path
            return fm.fileExists(atPath: rebased) ? rebased : nil
        }
        let resolved = Self.appSupportDir.appendingPathComponent(stored).path
        return fm.fileExists(atPath: resolved) ? resolved : nil
    }
    
    private func removeModelFolderPath(for modelId: String) {
        var paths = loadModelFolderPaths()
        paths.removeValue(forKey: modelId)
        UserDefaults.standard.set(paths, forKey: Self.modelFolderPathsKey)
        downloadedModels.remove(modelId)
    }
    
    private func loadModelFolderPaths() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.modelFolderPathsKey) as? [String: String] ?? [:]
    }
    
    // MARK: - Model State
    
    /// Checks all enabled models still exist on disk.
    private func validateDownloadedModels() {
        for modelId in loadModelFolderPaths().keys {
            // cachedModelFolder resolves relative and legacy absolute paths,
            // migrates entries, and clears the ones whose folders are gone.
            if cachedModelFolder(for: modelId) != nil {
                downloadedModels.insert(modelId)
            } else {
                downloadedModels.remove(modelId)
            }
        }
    }
    
    public func isModelDownloaded(_ modelName: String) -> Bool {
        downloadedModels.contains(modelName)
    }
    
    public func displayName(for modelId: String) -> String {
        if let known = Self.displayNames[modelId] { return known }
        // Cloud models: "berget:KBLab/kb-whisper-large" etc.
        if modelId.hasPrefix("berget:") {
            let apiId = String(modelId.dropFirst("berget:".count))
            if let friendly = Self.bergetASRDisplayNames[apiId] { return friendly }
            let shortName = apiId.components(separatedBy: "/").last ?? apiId
            return "\(shortName) (Berget)"
        }
        return modelId
    }

    private static let bergetASRDisplayNames: [String: String] = [
        "KBLab/kb-whisper-large": "KB Whisper Large (Berget)",
        "NbAiLab/nb-whisper-large": "NB Whisper Large (Berget)",
        "Systran/faster-whisper-large-v3": "Faster Whisper V3 (Berget)",
        "klang/pianissimo": "Klang Pianissimo (Berget)",
    ]
    
    // MARK: - Model Deletion
    
    public func deleteModel(_ modelName: String) {
        if let path = cachedModelFolder(for: modelName) {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
        }
        removeModelFolderPath(for: modelName)
    }
    
    public func modelSizeBytes(for modelName: String) -> Int64? {
        modelSizes[modelName]
    }
    
    public func getModelSizeString(_ modelName: String) -> String {
        guard let size = modelSizes[modelName] else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}