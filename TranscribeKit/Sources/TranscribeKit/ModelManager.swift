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
    ] + ParakeetModelSpec.all.map(\.id)

    public static let kbModels: [String] = allLocalModels.filter { $0.starts(with: "kb_whisper-") }
    public static let nbModels: [String] = allLocalModels.filter { $0.starts(with: "nb_whisper-") }
    public static let openAIModels: [String] = allLocalModels.filter { $0.starts(with: "openai_whisper-") }
    /// Parakeet-family models (Pianissimo, Parakeet v3) — fast enough for live transcription.
    public static let parakeetModels: [String] = ParakeetModelSpec.all.map(\.id)

    /// Which runtime transcribes a model id.
    public enum Engine: Sendable {
        case whisperKit
        case parakeet
        case cloud
    }

    /// The single place that maps a model id to its runtime; every router
    /// (transcription, download, prewarm, icons) goes through here so a new
    /// model family can't be half-wired.
    public static func engine(for modelId: String) -> Engine? {
        if modelId.hasPrefix("berget") { return .cloud }
        if ParakeetModelSpec.spec(for: modelId) != nil { return .parakeet }
        if modelId.hasPrefix("kb_whisper-") || modelId.hasPrefix("nb_whisper-") || modelId.hasPrefix("openai_whisper-") {
            return .whisperKit
        }
        return nil
    }

    /// Whether `languageCode` (ISO 639-1, or "auto") can be transcribed by
    /// `modelId`. Whisper and cloud models take any language; Parakeet-family
    /// models have a fixed set.
    public static func supports(languageCode: String, modelId: String) -> Bool {
        guard languageCode != "auto", let spec = ParakeetModelSpec.spec(for: modelId) else { return true }
        return spec.languageCodes.contains(languageCode)
    }

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
    ].merging(ParakeetModelSpec.all.map { ($0.id, $0.sizeBytes) }) { current, _ in current }

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
    ].merging(ParakeetModelSpec.all.map { ($0.id, $0.displayName) }) { current, _ in current }
    
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
    ]
    
    // MARK: - Model Deletion
    
    public func deleteModel(_ modelName: String) {
        if let path = cachedModelFolder(for: modelName) {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
        }
        if ParakeetModelSpec.spec(for: modelName) != nil {
            // Also drop a half-finished download so it can't linger unseen
            let staging = HuggingFaceDownloader.stagingDirectory(for: parakeetModelFolder(for: modelName))
            try? FileManager.default.removeItem(at: staging)
        }
        removeModelFolderPath(for: modelName)
    }

    /// Where a Parakeet-family model lives once downloaded.
    public func parakeetModelFolder(for modelId: String) -> URL {
        modelsDirectory.appendingPathComponent("Parakeet").appendingPathComponent(modelId)
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

// MARK: - Parakeet-family catalog

/// A Parakeet-family CoreML model (NVIDIA Parakeet TDT 0.6B v3 or a fine-tune
/// with the same component layout), as hosted on Hugging Face.
public struct ParakeetModelSpec: Sendable {
    public let id: String
    public let displayName: String
    public let repo: String
    /// Pinned commit: the files are fetched from exactly this revision and
    /// checked against its listing, so the repository owner can't change what
    /// the app runs. Bump deliberately, after testing the new revision.
    public let revision: String
    /// Top-level entries the runtime needs (the repos also carry builds for
    /// other runtimes that would triple the download).
    public let entries: [String]
    public let sizeBytes: Int64
    /// ISO 639-1 codes the model transcribes.
    public let languageCodes: Set<String>

    /// Languages of NVIDIA Parakeet TDT 0.6B v3. Norwegian is not among them.
    public static let parakeetV3Languages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    private static let componentEntries = [
        "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
    ]

    public static let all: [ParakeetModelSpec] = [
        // Klang AI's Swedish fine-tune of Parakeet v3 (CC BY 4.0). Klang has
        // not published a CoreML build for Swedish; this is the community
        // conversion its Danish sibling's layout matches.
        ParakeetModelSpec(
            id: "pianissimo_sv-coreml",
            displayName: "Pianissimo",
            repo: "magnushjelm/pianissimo-sv-coreml",
            revision: "ff8af835072b77a880991ce2d5402d249f923886",
            entries: componentEntries,
            sizeBytes: 631_000_000,
            languageCodes: ["sv"]
        ),
        ParakeetModelSpec(
            id: "parakeet_tdt-v3-coreml",
            displayName: "Parakeet v3",
            repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
            entries: componentEntries,
            sizeBytes: 483_000_000,
            languageCodes: parakeetV3Languages
        ),
    ]

    public static func spec(for modelId: String) -> ParakeetModelSpec? {
        all.first { $0.id == modelId }
    }
}
