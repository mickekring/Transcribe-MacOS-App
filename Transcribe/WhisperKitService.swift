import Foundation
import WhisperKit
import AVFoundation
import os

@MainActor
class WhisperKitService {
    /// Shared instance. WhisperKit model loading is expensive (multi-GB CoreML
    /// models with ANE specialization that can take minutes on a cold cache), so
    /// the app must have exactly one loading pipeline and keep the loaded model
    /// alive across transcriptions. Creating per-transcription instances causes
    /// concurrent duplicate loads that contend for CoreML/ANE and can wedge.
    static let shared = WhisperKitService()

    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "WhisperKit")

    var whisperKit: WhisperKit?
    private let languageManager = LanguageManager.shared
    private var initializationTask: Task<Void, Error>?
    private var initializingModelId: String?
    private var currentModelId: String?
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeCancellationFlag: TranscriptionCancellationFlag?
    /// In-flight model downloads by model id, cancellable from the UI.
    private var downloadTasks: [String: Task<URL, Error>] = [:]
    
    var currentModel: String? {
        return currentModelId
    }
    
    var availableModels: [String] {
        ModelManager.allLocalModels
    }

    /// Compute units for CoreML model loading. Defaults to the Neural Engine
    /// (WhisperKit's default): A/B testing on a 44-minute recording showed the
    /// GPU path degrades encoder output on these models — decoder repetition
    /// loops ("$$$...") and whole chunks misclassified as silence and dropped —
    /// while the ANE path matches cloud-quality output. The cost is ANE's
    /// ahead-of-time specialization compile on cold caches (minutes for large
    /// models), mitigated by the shared-instance model cache and the prewarm
    /// at app start. Set UserDefaults key "preferGPUCompute" to true to trade
    /// quality for fast loads.
    private var computeOptions: ModelComputeOptions {
        if UserDefaults.standard.bool(forKey: "preferGPUCompute") {
            return ModelComputeOptions(
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU
            )
        }
        return ModelComputeOptions()
    }

    /// Loads the user's selected model in the background so it's already in
    /// memory when the first transcription starts. Called at app launch; only
    /// prewarms models that are fully downloaded.
    func prewarmSelectedModel() {
        guard let modelId = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
              !modelId.isEmpty,
              modelId != "berget-kb-whisper-large",
              ModelManager.shared.cachedModelFolder(for: modelId) != nil else { return }
        Task { @MainActor in
            self.logger.info("Prewarming selected model \(modelId, privacy: .public) at launch")
            try? await self.initialize(modelId: modelId)
        }
    }
    
    // MARK: - Model Metadata
    
    /// Maps a model ID to the HuggingFace repo that hosts it.
    private func modelRepo(for modelId: String) -> String {
        if modelId.starts(with: "kb_whisper-") {
            return "mickekringai/kb-whisper-coreml"
        }
        if modelId.starts(with: "nb_whisper-") {
            return "digtek/whisperkit-nb-coreml"
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
        case "nb_whisper-tiny-coreml": return "NbAiLab_nb-whisper-tiny"
        case "nb_whisper-base-coreml": return "NbAiLab_nb-whisper-base"
        case "nb_whisper-small-coreml": return "NbAiLab_nb-whisper-small"
        case "nb_whisper-large-coreml": return "NbAiLab_nb-whisper-large"
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
        // Coalesce concurrent loads instead of misreporting them as
        // "model not found": await any in-flight initialization.
        while let task = initializationTask {
            if initializingModelId == modelId {
                try await task.value
                return
            }
            // A different model is loading — let it settle, then proceed.
            _ = try? await task.value
        }

        let task = Task { try await self.performInitialization(modelId: modelId) }
        initializationTask = task
        initializingModelId = modelId
        defer {
            initializationTask = nil
            initializingModelId = nil
        }
        try await task.value
    }

    private func performInitialization(modelId: String) async throws {
        let modelManager = ModelManager.shared
        let variant = modelVariant(for: modelId)
        let repo = modelRepo(for: modelId)
        let downloadBase = modelManager.downloadBase

        // Check if we already have this model downloaded locally
        if let cachedFolder = modelManager.cachedModelFolder(for: modelId) {
            logger.info("Loading cached model \(modelId, privacy: .public) from \(cachedFolder, privacy: .public)")
            // tokenizerFolder: resolve the tokenizer from our download base
            // (WhisperKit caches it there) so model load never needs the network.
            let config = WhisperKitConfig(
                modelFolder: cachedFolder,
                tokenizerFolder: downloadBase,
                computeOptions: computeOptions,
                verbose: true,
                download: false
            )

            do {
                let start = Date()
                let kit = try await WhisperKit(config)
                logger.info("Model \(modelId, privacy: .public) loaded in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
                whisperKit = kit
                currentModelId = modelId
                return
            } catch {
                // Cached model failed to load — fall through to re-download
                logger.error("Cached model \(modelId, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
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
                    tokenizerFolder: downloadBase,
                    computeOptions: computeOptions,
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
        logger.info("Model \(modelId, privacy: .public) not cached, downloading from \(repo, privacy: .public)")

        // Signal download started
        modelManager.isDownloading[modelId] = true
        modelManager.downloadProgress[modelId] = 0

        do {
            // Phase 1: Download with progress callback (cancellable from the UI)
            let modelFolder = try await runDownload(modelId: modelId, variant: variant, repo: repo, downloadBase: downloadBase)

            // Download complete
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress[modelId] = 1.0
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            
            // Phase 2: Load the downloaded model (no network needed)
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: downloadBase,
                computeOptions: computeOptions,
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
            cleanupPartialDownload(modelId: modelId)
            throw error
        }
    }

    /// Cancels an in-flight model download (from either the dropdown download
    /// or a transcription that triggered one).
    func cancelDownload(modelId: String) {
        logger.info("Cancelling download of \(modelId, privacy: .public)")
        downloadTasks[modelId]?.cancel()
    }

    /// Runs WhisperKit.download as a cancellable, UI-addressable task.
    private func runDownload(modelId: String, variant: String, repo: String, downloadBase: URL) async throws -> URL {
        let modelManager = ModelManager.shared
        let task = Task {
            try await WhisperKit.download(
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
        }
        downloadTasks[modelId] = task
        defer { downloadTasks[modelId] = nil }
        return try await task.value
    }

    /// Removes a partially downloaded model folder after a failed download so
    /// orphaned multi-gigabyte partials don't accumulate invisibly on disk.
    private func cleanupPartialDownload(modelId: String) {
        let modelManager = ModelManager.shared
        // Never remove a model that was previously recorded as fully downloaded
        guard modelManager.cachedModelFolder(for: modelId) == nil else { return }
        // Mirrors the HubApi layout used by WhisperKit.download:
        // {downloadBase}/models/{repo}/{variant}
        let folder = modelManager.downloadBase
            .appendingPathComponent("models")
            .appendingPathComponent(modelRepo(for: modelId))
            .appendingPathComponent(modelVariant(for: modelId))
        try? FileManager.default.removeItem(at: folder)
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
            let modelFolder = try await runDownload(modelId: modelId, variant: variant, repo: repo, downloadBase: downloadBase)

            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress[modelId] = 1.0
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            modelManager.saveModelFolderPath(modelFolder.path, for: modelId)
        } catch {
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress.removeValue(forKey: modelId)
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            cleanupPartialDownload(modelId: modelId)
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

    /// Cancels the in-flight transcription, if any. WhisperKit inference
    /// early-stops via the progress callback returning false.
    func cancelTranscription() {
        activeCancellationFlag?.cancel()
        activeTranscriptionTask?.cancel()
    }

    func transcribe(fileURL: URL, modelId: String, language: String?) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        let cancelFlag = TranscriptionCancellationFlag()
        activeCancellationFlag = cancelFlag

        return AsyncThrowingStream(TranscriptionUpdate.self) { continuation in
            let task = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    // Initialize WhisperKit if needed or if model changed
                    let needsInit = (self.whisperKit == nil || self.currentModelId != modelId)
                    if needsInit {
                        // Show appropriate status: "loading" if cached, "downloading" if not
                        let isCached = ModelManager.shared.cachedModelFolder(for: modelId) != nil
                        let isAlreadyDownloading = ModelManager.shared.isDownloading[modelId] == true
                        let statusMessage: String
                        if isCached {
                            statusMessage = String(format: NSLocalizedString("loading_model_status", comment: ""), ModelManager.shared.displayName(for: modelId))
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

                        // Heartbeat while the model loads: a cold ANE
                        // specialization of a large model can take minutes,
                        // and without periodic updates it looks like a hang.
                        let loadStart = Date()
                        // A load that runs past ~10s means macOS is building
                        // its optimized version of the model (ANE
                        // specialization) — switch to a status that explains
                        // the wait in plain language, with a ticking clock.
                        let heartbeat = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(10))
                            while !Task.isCancelled {
                                let elapsed = Int(Date().timeIntervalSince(loadStart))
                                let elapsedText = elapsed >= 60
                                    ? "\(elapsed / 60) min \(elapsed % 60) s"
                                    : "\(elapsed) s"
                                continuation.yield(TranscriptionUpdate(
                                    text: String(format: NSLocalizedString("model_optimizing_status", comment: ""),
                                                 ModelManager.shared.displayName(for: modelId), elapsedText),
                                    progress: 0.01,
                                    segments: [],
                                    isComplete: false
                                ))
                                try? await Task.sleep(for: .seconds(5))
                            }
                        }
                        defer { heartbeat.cancel() }

                        try await self.initialize(modelId: modelId)
                    }

                    try Task.checkCancellation()

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
                    
                    let wordTimestamps = UserDefaults.standard.bool(forKey: "wordTimestamps")

                    // Create decoding options.
                    // - usePrefillPrompt MUST be true for the language to be
                    //   enforced: WhisperKit applies it by prefilling the decoder
                    //   with [SOT, <language>, <task>]. Without it the model
                    //   re-detects language every 30s window and drifts into
                    //   English translation on Swedish audio.
                    // - withoutTimestamps stays false: timestamp tokens anchor
                    //   long-form window seeking; decoding without them makes
                    //   repetition loops/hallucination far more likely on long
                    //   files. skipSpecialTokens keeps them out of the text.
                    // chunkingStrategy .vad splits long audio at silence
                    // boundaries and decodes chunks independently — a chunk that
                    // falls into a repetition loop can't poison the rest of the
                    // file, which matters for 45+ minute recordings.
                    let decodeOptions = DecodingOptions(
                        task: .transcribe,
                        language: languageCode == "auto" ? nil : languageCode,
                        usePrefillPrompt: true,
                        skipSpecialTokens: true,
                        withoutTimestamps: false,
                        wordTimestamps: wordTimestamps,
                        // One worker: chunks stream sequentially into the live
                        // preview. Concurrent workers interleave windowIds and
                        // the streamed text appears to be written by several
                        // hands at once.
                        concurrentWorkerCount: 1,
                        chunkingStrategy: .vad
                    )
                    
                    // Wrap mutable callback state in a Sendable container
                    // This is safe because the callback is only invoked synchronously
                    // within WhisperKit's transcription loop on a single thread.
                    let callbackState = StreamingCallbackState(continuation: continuation)
                    
                    // Transcribe with streaming callback. Returning false from
                    // the callback early-stops WhisperKit inference on cancel.
                    let callback: @Sendable (TranscriptionProgress) -> Bool? = { progress in
                        guard !cancelFlag.isCancelled else { return false }
                        return callbackState.handleProgress(progress)
                    }
                    self.logger.info("Transcription started: \(fileURL.lastPathComponent, privacy: .public) model=\(modelId, privacy: .public)")
                    let transcribeStart = Date()
                    let results = try await whisperKit.transcribe(
                        audioPath: fileURL.path,
                        decodeOptions: decodeOptions,
                        callback: callback
                    )
                    self.logger.info("Transcription finished in \(Date().timeIntervalSince(transcribeStart), format: .fixed(precision: 1))s")

                    // If cancelled, don't report the partial output as a
                    // successful, complete transcription.
                    if cancelFlag.isCancelled || Task.isCancelled {
                        throw CancellationError()
                    }

                    // Finalize the callback state (saves last window text)
                    callbackState.finalize()
                    
                    // Process final result. VAD chunking returns one
                    // TranscriptionResult per chunk — merge them all; taking
                    // only the first would drop most of the transcription.
                    let merged = TranscriptionUtilities.mergeTranscriptionResults(results)
                    let fullText = merged.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")

                    let finalSegments = merged.segments.map { segment in
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
                    
                    continuation.finish()
                    
                } catch {
                    // Propagate the error instead of silently substituting mock output
                    continuation.finish(throwing: error)
                }
            }

            self.activeTranscriptionTask = task

            // When the consumer stops iterating (or the stream finishes),
            // cancel the producer so inference stops promptly.
            continuation.onTermination = { @Sendable _ in
                cancelFlag.cancel()
                task.cancel()
            }
        }
    }
}

// Thread-safe cancellation flag shared between the producer task, the stream's
// onTermination handler, and WhisperKit's progress callback (which may run
// outside the producer task's context, where Task.isCancelled is unreliable).
private final class TranscriptionCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
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
        currentWindowText = Self.strippingSpecialTokens(progress.text).trimmingCharacters(in: .whitespaces)
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

    /// Removes `<|...|>` special-token markers (timestamps etc.) from streaming
    /// text — decoding runs with timestamp tokens for long-form anchoring, but
    /// they shouldn't appear in the live preview.
    private static func strippingSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
    }
}

extension TranscriptionError {
    static let initializationTimeout = TranscriptionError.modelNotFound
}
