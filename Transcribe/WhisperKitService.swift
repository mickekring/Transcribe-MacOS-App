import Foundation
import WhisperKit
import AVFoundation

@MainActor
class WhisperKitService {
    var whisperKit: WhisperKit?
    private let languageManager = LanguageManager.shared
    private var isInitializing = false
    private var currentModelId: String?
    
    var currentModel: String? {
        return currentModelId
    }
    
    var availableModels: [String] {
        ModelManager.allLocalModels
    }
    
    // MARK: - Model Metadata
    
    /// Maps a model ID to the HuggingFace repo that hosts it.
    private func modelRepo(for modelId: String) -> String {
        if modelId.starts(with: "kb_whisper-") {
            return "mickekringai/kb-whisper-coreml"
        }
        return "argmaxinc/whisperkit-coreml"
    }
    
    /// Maps a model ID to the WhisperKit variant name used inside the repo.
    private func modelVariant(for modelId: String) -> String {
        switch modelId {
        case "kb_whisper-base-coreml": return "base"
        case "kb_whisper-small-coreml": return "small"
        case "kb_whisper-medium-coreml": return "medium"
        case "kb_whisper-large-coreml": return "large"
        case "openai_whisper-base": return "openai_whisper-base"
        case "openai_whisper-small": return "openai_whisper-small"
        case "openai_whisper-medium": return "openai_whisper-medium"
        case "openai_whisper-large-v2": return "openai_whisper-large-v2"
        case "openai_whisper-large-v3": return "openai_whisper-large-v3"
        default: return "openai_whisper-base"
        }
    }
    
    // MARK: - Initialization
    
    func initialize(modelId: String) async throws {
        guard !isInitializing else {
            throw TranscriptionError.modelNotFound
        }
        isInitializing = true
        defer { isInitializing = false }
        
        let modelManager = ModelManager.shared
        let variant = modelVariant(for: modelId)
        let repo = modelRepo(for: modelId)
        let downloadBase = modelManager.downloadBase
        
        // Check if we already have this model downloaded locally
        if let cachedFolder = modelManager.cachedModelFolder(for: modelId) {
            let config = WhisperKitConfig(
                modelFolder: cachedFolder,
                verbose: true,
                download: false
            )
            
            do {
                let kit = try await WhisperKit(config)
                whisperKit = kit
                currentModelId = modelId
                return
            } catch {
                // Cached model failed to load — fall through to re-download
                modelManager.deleteModel(modelId)
            }
        }
        
        // If a background download is already in progress (from dropdown selection),
        // wait for it to finish instead of starting a second download.
        if modelManager.isDownloading[modelId] == true {
            while modelManager.isDownloading[modelId] == true {
                try await Task.sleep(for: .milliseconds(200))
            }
            // Download finished — check if model is now cached
            if let cachedFolder = modelManager.cachedModelFolder(for: modelId) {
                let config = WhisperKitConfig(
                    modelFolder: cachedFolder,
                    verbose: true,
                    download: false
                )
                let kit = try await WhisperKit(config)
                whisperKit = kit
                currentModelId = modelId
                return
            }
            // If download failed, fall through to re-download below
        }
        
        // Model not cached locally — download with progress tracking, then load
        
        // Signal download started
        modelManager.isDownloading[modelId] = true
        modelManager.downloadProgress[modelId] = 0
        
        do {
            // Phase 1: Download via WhisperKit.download() with progress callback
            let modelFolder = try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                from: repo,
                progressCallback: { progress in
                    let fraction = Double(progress.completedUnitCount) / max(Double(progress.totalUnitCount), 1)
                    let speed = progress.userInfo[.throughputKey] as? Double
                    Task { @MainActor in
                        modelManager.downloadProgress[modelId] = fraction
                        if let speed {
                            modelManager.downloadSpeed[modelId] = speed
                        }
                    }
                }
            )
            
            // Download complete
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress[modelId] = 1.0
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            
            // Phase 2: Load the downloaded model (no network needed)
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                verbose: true,
                download: false
            )
            
            let kit = try await WhisperKit(config)
            whisperKit = kit
            currentModelId = modelId
            
            // Persist the resolved model folder path for future offline use
            modelManager.saveModelFolderPath(modelFolder.path, for: modelId)
        } catch {
            // Clear download state on failure
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress.removeValue(forKey: modelId)
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            whisperKit = nil
            throw error
        }
    }
    
    /// Downloads a model without loading it into memory.
    /// Used when the user selects a non-downloaded model from the dropdown.
    func downloadOnly(modelId: String) async throws {
        let modelManager = ModelManager.shared
        
        // Skip if already downloaded or already downloading
        guard modelManager.cachedModelFolder(for: modelId) == nil else { return }
        guard modelManager.isDownloading[modelId] != true else { return }
        
        let variant = modelVariant(for: modelId)
        let repo = modelRepo(for: modelId)
        let downloadBase = modelManager.downloadBase
        
        modelManager.isDownloading[modelId] = true
        modelManager.downloadProgress[modelId] = 0
        
        do {
            let modelFolder = try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                from: repo,
                progressCallback: { progress in
                    let fraction = Double(progress.completedUnitCount) / max(Double(progress.totalUnitCount), 1)
                    let speed = progress.userInfo[.throughputKey] as? Double
                    Task { @MainActor in
                        modelManager.downloadProgress[modelId] = fraction
                        if let speed {
                            modelManager.downloadSpeed[modelId] = speed
                        }
                    }
                }
            )
            
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress[modelId] = 1.0
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            modelManager.saveModelFolderPath(modelFolder.path, for: modelId)
        } catch {
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress.removeValue(forKey: modelId)
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            throw error
        }
    }
    
    func loadModel(_ modelName: String) async throws {
        try await initialize(modelId: modelName)
    }
    
    func unloadModel() {
        whisperKit = nil
        currentModelId = nil
    }
    
    func transcribe(fileURL: URL, modelId: String, language: String?) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    // Initialize WhisperKit if needed or if model changed
                    let needsInit = (self.whisperKit == nil || self.currentModelId != modelId)
                    if needsInit {
                        // Show appropriate status: "loading" if cached, "downloading" if not
                        let isCached = ModelManager.shared.cachedModelFolder(for: modelId) != nil
                        let isAlreadyDownloading = ModelManager.shared.isDownloading[modelId] == true
                        let statusMessage: String
                        if isCached {
                            statusMessage = String(format: NSLocalizedString("preparing_model_first_use", comment: ""), ModelManager.shared.displayName(for: modelId))
                        } else if isAlreadyDownloading {
                            statusMessage = String(format: NSLocalizedString("downloading_model", comment: ""), ModelManager.shared.displayName(for: modelId))
                        } else {
                            statusMessage = NSLocalizedString("downloading_whisperkit_model", comment: "")
                        }
                        
                        continuation.yield(TranscriptionUpdate(
                            text: statusMessage,
                            progress: 0.01,
                            segments: [],
                            isComplete: false
                        ))
                        
                        try await self.initialize(modelId: modelId)
                    }
                    
                    guard let whisperKit = self.whisperKit else {
                        throw TranscriptionError.modelNotFound
                    }
                    
                    // Initial progress
                    continuation.yield(TranscriptionUpdate(
                        text: NSLocalizedString("initializing_whisperkit", comment: ""),
                        progress: 0.05,
                        segments: [],
                        isComplete: false
                    ))
                    
                    // Loading audio
                    continuation.yield(TranscriptionUpdate(
                        text: NSLocalizedString("loading_audio_file", comment: ""),
                        progress: 0.1,
                        segments: [],
                        isComplete: false
                    ))
                    
                    // Get language code for transcription
                    let languageCode = language ?? "auto"
                    
                    // Get timestamp settings from UserDefaults
                    let includeTimestamps = UserDefaults.standard.bool(forKey: "includeTimestamps")
                    let wordTimestamps = UserDefaults.standard.bool(forKey: "wordTimestamps")
                    
                    // Create decoding options
                    let decodeOptions = DecodingOptions(
                        task: .transcribe,
                        language: languageCode == "auto" ? nil : languageCode,
                        usePrefillPrompt: false,
                        usePrefillCache: false,
                        skipSpecialTokens: true,
                        withoutTimestamps: !includeTimestamps,
                        wordTimestamps: wordTimestamps
                    )
                    
                    // Wrap mutable callback state in a Sendable container
                    // This is safe because the callback is only invoked synchronously
                    // within WhisperKit's transcription loop on a single thread.
                    let callbackState = StreamingCallbackState(continuation: continuation)
                    
                    // Transcribe with streaming callback
                    let callback: @Sendable (TranscriptionProgress) -> Bool? = { progress in
                        callbackState.handleProgress(progress)
                    }
                    let results = try await whisperKit.transcribe(
                        audioPath: fileURL.path,
                        decodeOptions: decodeOptions,
                        callback: callback
                    )
                    
                    // Finalize the callback state (saves last window text)
                    callbackState.finalize()
                    
                    // Process final result
                    if let firstResult = results.first {
                        let fullText = firstResult.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                        
                        let finalSegments = firstResult.segments.map { segment in
                            TranscriptionSegmentData(
                                start: Double(segment.start),
                                end: Double(segment.end),
                                text: segment.text,
                                words: nil
                            )
                        }
                        
                        continuation.yield(TranscriptionUpdate(
                            text: fullText,
                            progress: 1.0,
                            segments: finalSegments,
                            isComplete: true
                        ))
                    } else {
                        continuation.yield(TranscriptionUpdate(
                            text: "",
                            progress: 1.0,
                            segments: [],
                            isComplete: true
                        ))
                    }
                    
                    continuation.finish()
                    
                } catch {
                    // Propagate the error instead of silently substituting mock output
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// Wraps mutable streaming state so it can be captured by a @Sendable callback.
// All access is serialized by WhisperKit's transcription loop, so this is safe.
private final class StreamingCallbackState: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    private var lastUpdateTime = Date()
    private let updateInterval: TimeInterval = 0.2
    private var completedSegments: [Int: String] = [:]
    private var currentWindowId = -1
    private var currentWindowText = ""
    private var lastDisplayedText = ""
    private let startTime = Date()
    private var maxWindowId = 0
    
    init(continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation) {
        self.continuation = continuation
    }
    
    func handleProgress(_ progress: TranscriptionProgress) -> Bool {
        let now = Date()
        
        if progress.windowId != currentWindowId {
            if currentWindowId >= 0 && !currentWindowText.isEmpty {
                completedSegments[currentWindowId] = currentWindowText.trimmingCharacters(in: .whitespaces)
            }
            currentWindowId = progress.windowId
        }
        currentWindowText = progress.text.trimmingCharacters(in: .whitespaces)
        maxWindowId = max(maxWindowId, progress.windowId)
        
        // Build the complete text from all segments
        var fullText = ""
        
        let sortedWindows = completedSegments.keys.sorted()
        for windowId in sortedWindows {
            if let segmentText = completedSegments[windowId] {
                if !fullText.isEmpty {
                    fullText += " "
                }
                fullText += segmentText
            }
        }
        
        if !fullText.isEmpty && !currentWindowText.isEmpty {
            fullText += " " + currentWindowText
        } else if fullText.isEmpty {
            fullText = currentWindowText
        }
        
        let textChanged = fullText != lastDisplayedText
        let timeElapsed = now.timeIntervalSince(lastUpdateTime) >= updateInterval
        
        if textChanged || timeElapsed {
            lastUpdateTime = now
            lastDisplayedText = fullText
            
            let elapsedTime = now.timeIntervalSince(startTime)
            let segmentCount = Double(completedSegments.count + 1)
            
            let timeProgress = min(elapsedTime / 20.0, 0.9)
            let segmentProgress = min(segmentCount / 10.0, 0.9)
            let estimatedProgress = min(0.3 + max(timeProgress, segmentProgress) * 0.65, 0.95)
            
            continuation.yield(TranscriptionUpdate(
                text: fullText.isEmpty ? "Transkriberar..." : fullText,
                progress: estimatedProgress,
                segments: [],
                isComplete: false
            ))
        }
        
        return true
    }
    
    func finalize() {
        if currentWindowId >= 0 && !currentWindowText.isEmpty {
            completedSegments[currentWindowId] = currentWindowText
        }
    }
}

extension TranscriptionError {
    static let initializationTimeout = TranscriptionError.modelNotFound
}
