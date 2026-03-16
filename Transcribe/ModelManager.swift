import Foundation
import SwiftUI

class ModelManager: ObservableObject {
    nonisolated(unsafe) static let shared = ModelManager()
    
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadedModels: Set<String> = []
    @Published var isDownloading: [String: Bool] = [:]
    @Published var downloadSpeed: [String: Double] = [:]  // bytes/sec
    
    /// All available local model IDs
    static let allLocalModels: [String] = [
        "kb_whisper-base-coreml",
        "kb_whisper-small-coreml",
        "kb_whisper-medium-coreml",
        "kb_whisper-large-coreml",
        "openai_whisper-base",
        "openai_whisper-small",
        "openai_whisper-medium",
        "openai_whisper-large-v2",
        "openai_whisper-large-v3",
    ]
    
    static let kbModels: [String] = allLocalModels.filter { $0.starts(with: "kb_whisper-") }
    static let openAIModels: [String] = allLocalModels.filter { $0.starts(with: "openai_whisper-") }
    
    private let modelSizes: [String: Int64] = [
        "kb_whisper-base-coreml": 145_000_000,
        "kb_whisper-small-coreml": 483_000_000,
        "kb_whisper-medium-coreml": 1_530_000_000,
        "kb_whisper-large-coreml": 3_090_000_000,
        "openai_whisper-base": 145_000_000,
        "openai_whisper-small": 483_000_000,
        "openai_whisper-medium": 1_530_000_000,
        "openai_whisper-large-v2": 3_090_000_000,
        "openai_whisper-large-v3": 3_090_000_000,
    ]
    
    private static let displayNames: [String: String] = [
        "kb_whisper-base-coreml": "KB Whisper Base",
        "kb_whisper-small-coreml": "KB Whisper Small",
        "kb_whisper-medium-coreml": "KB Whisper Medium",
        "kb_whisper-large-coreml": "KB Whisper Large",
        "openai_whisper-base": "Whisper Base",
        "openai_whisper-small": "Whisper Small",
        "openai_whisper-medium": "Whisper Medium",
        "openai_whisper-large-v2": "Whisper Large v2",
        "openai_whisper-large-v3": "Whisper Large v3",
        "berget-kb-whisper-large": "KB Whisper Large (Berget)",
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
    var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.transcribe.app"
        return appSupport.appendingPathComponent(bundleID).appendingPathComponent("Models")
    }
    
    /// The download base passed to WhisperKit/HubApi so models are stored
    /// inside Application Support instead of ~/Documents/huggingface.
    var downloadBase: URL {
        modelsDirectory.appendingPathComponent("HuggingFace")
    }
    
    private func createModelsDirectory() {
        try? FileManager.default.createDirectory(at: downloadBase,
                                                withIntermediateDirectories: true)
    }
    
    // MARK: - Model Folder Path Tracking
    
    /// Returns the persisted local folder path for a previously downloaded model, or nil if not yet downloaded.
    func cachedModelFolder(for modelId: String) -> String? {
        let paths = loadModelFolderPaths()
        guard let path = paths[modelId] else { return nil }
        
        // Verify the folder still exists on disk
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Model folder was deleted externally — clear the stale entry
            removeModelFolderPath(for: modelId)
            return nil
        }
        return path
    }
    
    /// Persists the local folder path after a successful model download.
    func saveModelFolderPath(_ path: String, for modelId: String) {
        var paths = loadModelFolderPaths()
        paths[modelId] = path
        UserDefaults.standard.set(paths, forKey: Self.modelFolderPathsKey)
        downloadedModels.insert(modelId)
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
        let paths = loadModelFolderPaths()
        for (modelId, path) in paths {
            if FileManager.default.fileExists(atPath: path) {
                downloadedModels.insert(modelId)
            } else {
                removeModelFolderPath(for: modelId)
            }
        }
    }
    
    func isModelDownloaded(_ modelName: String) -> Bool {
        downloadedModels.contains(modelName)
    }
    
    func displayName(for modelId: String) -> String {
        Self.displayNames[modelId] ?? modelId
    }
    
    // MARK: - Model Deletion
    
    func deleteModel(_ modelName: String) {
        if let path = cachedModelFolder(for: modelName) {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
        }
        removeModelFolderPath(for: modelName)
    }
    
    func modelSizeBytes(for modelName: String) -> Int64? {
        modelSizes[modelName]
    }
    
    func getModelSizeString(_ modelName: String) -> String {
        guard let size = modelSizes[modelName] else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}