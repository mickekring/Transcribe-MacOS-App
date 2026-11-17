import Foundation
import WhisperKit
import AVFoundation
import os

@MainActor
public class WhisperKitService {
    /// Shared instance. WhisperKit model loading is expensive (multi-GB CoreML
    /// models with ANE specialization that can take minutes on a cold cache), so
    /// the app must have exactly one loading pipeline and keep the loaded model
    /// alive across transcriptions. Creating per-transcription instances causes
    /// concurrent duplicate loads that contend for CoreML/ANE and can wedge.
    public static let shared = WhisperKitService()

    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "WhisperKit")

    public var whisperKit: WhisperKit?
    private let languageManager = LanguageManager.shared
    private var initializationTask: Task<Void, Error>?
    private var initializingModelId: String?
    private var currentModelId: String?
    /// Bumped by `unloadModel()`. A load compares the value it started with
    /// against the current one before installing its model, so an unload that
    /// arrives while a load is in flight is not undone when the load finishes.
    private var unloadGeneration = 0
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeCancellationFlag: TranscriptionCancellationFlag?
    /// In-flight model downloads by model id, cancellable from the UI.
    private var downloadTasks: [String: Task<URL, Error>] = [:]
    /// Model ids whose in-flight download the user explicitly cancelled.
    private var userCancelledDownloads: Set<String> = []
    
    public var currentModel: String? {
        return currentModelId
    }
    
    public var availableModels: [String] {
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
    public func prewarmSelectedModel() {
        guard let modelId = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
              !modelId.isEmpty,
              ModelManager.engine(for: modelId) == .whisperKit,
              ModelManager.shared.cachedModelFolder(for: modelId) != nil else { return }
        Task { @MainActor in
            self.logger.info("Prewarming selected model \(modelId, privacy: .public) at launch")
            try? await self.initialize(modelId: modelId)
        }
    }
    
    // MARK: - Model Metadata
    
    /// Maps a model ID to the HuggingFace repo that hosts it.
    nonisolated static func modelRepo(for modelId: String) -> String {
        if modelId.starts(with: "kb_whisper-") {
            return "mickekringai/kb-whisper-coreml"
        }
        if modelId.starts(with: "nb_whisper-") {
            return "digtek/whisperkit-nb-coreml"
        }
        return "argmaxinc/whisperkit-coreml"
    }

    /// Maps a model ID to the WhisperKit variant name used inside the repo,
    /// or nil for an id this app does not ship. There is deliberately no
    /// default: a fallback variant would download a different model and file
    /// it under the unknown id.
    nonisolated static func modelVariant(for modelId: String) -> String? {
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
        default: return nil
        }
    }

    /// Where the Hub downloader puts a model's finished files:
    /// `{downloadBase}/models/{repo}/{variant}` (HubApi.localRepoLocation
    /// plus the variant folder WhisperKit.download matches).
    nonisolated static func defaultModelFolder(for modelId: String, downloadBase: URL) -> URL? {
        guard let variant = modelVariant(for: modelId) else { return nil }
        return downloadBase
            .appendingPathComponent("models")
            .appendingPathComponent(modelRepo(for: modelId))
            .appendingPathComponent(variant)
    }

    /// The Hub downloader's staging area for a model folder:
    /// `{repo}/.cache/huggingface/download/{variant}`. Files that are still
    /// transferring live there as `<name>.<etag>.incomplete` — for a model
    /// that is the multi-gigabyte weights — next to one small `.metadata`
    /// file per finished file (HubApi.snapshot).
    nonisolated static func stagingDirectory(forModelFolder folder: URL) -> URL {
        folder.deletingLastPathComponent()
            .appendingPathComponent(".cache/huggingface/download")
            .appendingPathComponent(folder.lastPathComponent)
    }
    
    // MARK: - Initialization
    
    public func initialize(modelId: String) async throws {
        // Only ids this service ships belong here: another engine's model, if
        // it got this far, would be loaded as Whisper files and — its folder
        // not looking like a Whisper model — deleted as an incomplete one.
        guard ModelManager.engine(for: modelId) == .whisperKit,
              Self.modelVariant(for: modelId) != nil else {
            throw TranscriptionError.unsupportedModel
        }
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

        // Already in memory: a reload would cost seconds to minutes and hold
        // two copies of the model while it runs.
        if whisperKit != nil, currentModelId == modelId { return }

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
        guard let variant = Self.modelVariant(for: modelId) else {
            throw TranscriptionError.unsupportedModel
        }
        let modelManager = ModelManager.shared
        let repo = Self.modelRepo(for: modelId)
        let downloadBase = modelManager.downloadBase
        let generation = unloadGeneration

        // Check if we already have this model downloaded locally
        if let cachedFolder = modelManager.cachedModelFolder(for: modelId) {
            logger.info("Loading cached model \(modelId, privacy: .public) from \(cachedFolder, privacy: .private)")
            do {
                try await loadAndInstall(modelId, from: cachedFolder, generation: generation)
                return
            } catch is CancellationError {
                // Unloaded while loading: nothing is wrong with the files
                throw CancellationError()
            } catch {
                // The description can embed the model's path, so it stays private
                logger.error("Cached model \(modelId, privacy: .public) failed to load: \(error.localizedDescription, privacy: .private)")
                // Only a folder that is missing files is worth deleting. Any
                // other failure — memory pressure, a Neural Engine compile
                // that gave up, a tokenizer that needs the network — would
                // not be cured by a re-download, and deleting the files would
                // cost the user gigabytes for nothing.
                guard !modelFolderIsComplete(URL(fileURLWithPath: cachedFolder)) else { throw error }
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
                try await loadAndInstall(modelId, from: cachedFolder, generation: generation)
                return
            }
            // The user cancelled that download; starting it again here would
            // undo the cancel.
            if userCancelledDownloads.contains(modelId) {
                throw CancellationError()
            }
            // It failed for another reason — fall through and retry it below
        }

        // Model not cached locally — download with progress tracking, then load
        logger.info("Model \(modelId, privacy: .public) not cached, downloading from \(repo, privacy: .public)")

        do {
            let modelFolder = try await downloadModel(modelId: modelId, variant: variant, repo: repo, downloadBase: downloadBase)
            try await loadAndInstall(modelId, from: modelFolder.path, generation: generation)
        } catch {
            whisperKit = nil
            throw error
        }
    }

    /// Loads the model in `folder` and makes it the current model.
    private func loadAndInstall(_ modelId: String, from folder: String, generation: Int) async throws {
        // An unload that arrived while the model was still downloading: the
        // model is no longer wanted in memory, so don't start loading it.
        guard generation == unloadGeneration else { throw CancellationError() }

        // tokenizerFolder: the tokenizer lives under our download base (it is
        // fetched there with the model, see downloadTokenizerIfNeeded).
        let config = WhisperKitConfig(
            modelFolder: folder,
            tokenizerFolder: ModelManager.shared.downloadBase,
            computeOptions: computeOptions,
            verbose: true,
            download: false
        )
        let start = Date()
        let kit = try await TranscribeWhisperKit(config)

        // An unload during the load wins: installing the model now would
        // bring back the memory the caller just freed.
        guard generation == unloadGeneration else { throw CancellationError() }

        logger.info("Model \(modelId, privacy: .public) loaded in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
        whisperKit = kit
        currentModelId = modelId
    }

    /// Downloads a model and records it as available, keeping the download
    /// state the UI observes up to date. Both ways a download can start (the
    /// model dropdown, a transcription with a model that isn't on disk yet)
    /// go through here.
    private func downloadModel(modelId: String, variant: String, repo: String, downloadBase: URL) async throws -> URL {
        let modelManager = ModelManager.shared
        modelManager.isDownloading[modelId] = true
        modelManager.downloadProgress[modelId] = 0

        do {
            let modelFolder = try await runDownload(modelId: modelId, variant: variant, repo: repo, downloadBase: downloadBase)

            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress[modelId] = 1.0
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            // Recorded as soon as the files are verified, not after the first
            // successful load: a load can fail for reasons that have nothing
            // to do with the download, and must not cost the user the files.
            modelManager.saveModelFolderPath(modelFolder.path, for: modelId)
            return modelFolder
        } catch {
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress.removeValue(forKey: modelId)
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            // A cancelled download is abandoned; a failed one keeps its
            // partial files so the next attempt resumes.
            if error is CancellationError {
                cleanupPartialDownload(modelId: modelId)
            }
            throw error
        }
    }

    /// Cancels an in-flight model download (from either the dropdown download
    /// or a transcription that triggered one).
    public func cancelDownload(modelId: String) {
        logger.info("Cancelling download of \(modelId, privacy: .public)")
        userCancelledDownloads.insert(modelId)
        downloadTasks[modelId]?.cancel()
    }

    /// Whether a model folder contains everything WhisperKit needs to load.
    /// The vendored Hub downloader returns "success" when its task is
    /// cancelled mid-transfer, so a returned folder must never be trusted
    /// without this check — accepting a partial folder marks a broken model
    /// as downloaded.
    private func modelFolderIsComplete(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("config.json").path) else { return false }
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let compiled = folder.appendingPathComponent("\(component).mlmodelc")
            for required in ["weights/weight.bin", "model.mil", "coremldata.bin"] {
                guard fm.fileExists(atPath: compiled.appendingPathComponent(required).path) else { return false }
            }
        }
        return true
    }

    /// Runs WhisperKit.download as a cancellable, UI-addressable task.
    /// Watchdog marker: a download attempt made no progress and was aborted.
    private struct DownloadStalledError: Error {}

    enum ModelDownloadError: LocalizedError {
        case stalledRepeatedly
        case localOnlyMode
        /// Local-only mode is on and the model's tokenizer is not on disk, so
        /// loading the model would mean a request to the Hub.
        case tokenizerNeedsNetwork

        var errorDescription: String? {
            switch self {
            case .stalledRepeatedly:
                return "The download kept stalling. Check your internet connection and try again."
            case .localOnlyMode:
                return "Local-only mode is enabled — model downloads are disabled. Turn it off in Settings to download models."
            case .tokenizerNeedsNetwork:
                return localized("local_only_tokenizer_missing")
            }
        }
    }

    /// Downloads a model with automatic stall recovery: if no progress is
    /// made for 30 seconds (HuggingFace's CDN is prone to stalling sustained
    /// multi-GB transfers), the attempt is cancelled and retried — the
    /// downloader resumes from its partial `.incomplete` file, so a stall
    /// costs seconds, not a restart.
    private func runDownload(modelId: String, variant: String, repo: String, downloadBase: URL) async throws -> URL {
        guard !UserDefaults.standard.bool(forKey: "localOnlyMode") else {
            throw ModelDownloadError.localOnlyMode
        }
        userCancelledDownloads.remove(modelId)
        var attempt = 1
        while true {
            do {
                let folder = try await runDownloadAttempt(modelId: modelId, variant: variant, repo: repo, downloadBase: downloadBase)
                // The downloader reports success even when cancelled
                // mid-transfer — only a verified-complete folder counts.
                if modelFolderIsComplete(folder) {
                    try await downloadTokenizerIfNeeded(forModelIn: folder, modelId: modelId, downloadBase: downloadBase)
                    // A cancel during the tokenizer fetch has no task to stop
                    // (it is a few megabytes), but it is still a cancel.
                    if userCancelledDownloads.contains(modelId) {
                        throw CancellationError()
                    }
                    return folder
                }
                if userCancelledDownloads.contains(modelId) {
                    throw CancellationError()
                }
                logger.warning("Download of \(modelId, privacy: .public) returned an incomplete folder — resuming")
                throw DownloadStalledError()
            } catch is DownloadStalledError {
                if userCancelledDownloads.contains(modelId) {
                    throw CancellationError()
                }
                // Each stalled attempt costs at most ~35s and resumes from
                // the partial bytes, so a generous budget rides out long
                // CDN bad patches (observed: 10+ consecutive stalls).
                guard attempt < 20 else {
                    logger.error("Download of \(modelId, privacy: .public) stalled after \(attempt) attempts, giving up")
                    throw ModelDownloadError.stalledRepeatedly
                }
                attempt += 1
                logger.warning("Download of \(modelId, privacy: .public) stalled, retrying (attempt \(attempt)) — resuming from partial file")
            } catch {
                // The downloader reports a cancelled transfer as
                // URLError(.cancelled) (Downloader.cancel). Whatever shape it
                // takes, a download the user cancelled ends as a
                // cancellation, never as an error to show.
                if userCancelledDownloads.contains(modelId) {
                    throw CancellationError()
                }
                throw error
            }
        }
    }

    /// Fetches the tokenizer a freshly downloaded model needs, unless
    /// WhisperKit can already load one from disk.
    ///
    /// The model repositories hold only the CoreML files. Left alone,
    /// WhisperKit downloads the tokenizer the first time the model is loaded
    /// — also with `download: false`, which only governs the model files —
    /// so a "downloaded" model would still need the network once. Fetching it
    /// here makes the download complete. It goes through the Hub client and
    /// to the location WhisperKit itself would use, so the load finds the
    /// files where it looks first.
    private func downloadTokenizerIfNeeded(forModelIn folder: URL, modelId: String, downloadBase: URL) async throws {
        guard let repoId = WhisperTokenizerFiles.repoId(forModelFolder: folder) else {
            // Without the model's dimensions there is no telling which
            // tokenizer it wants; WhisperKit resolves it at first load, as it
            // did before.
            logger.warning("Could not determine the tokenizer for \(modelId, privacy: .public) from its config.json")
            return
        }
        guard WhisperTokenizerFiles.localFolder(repoId: repoId, tokenizerBase: downloadBase, modelFolder: folder) == nil else {
            return
        }
        logger.info("Downloading tokenizer \(repoId, privacy: .public) for \(modelId, privacy: .public)")
        _ = try await HubApiWrapper(downloadBase: downloadBase)
            .snapshot(from: HubApiWrapper.Repo(id: repoId), matching: WhisperTokenizerFiles.downloadedFiles)
    }

    /// Total bytes of the model currently on disk: the final variant folder
    /// plus the Hub downloader's staging area, where the large weight files
    /// accumulate as `.incomplete` until they finish. This is the ground
    /// truth for both progress and stall detection — the SDK's Progress
    /// counts files (20 equal slices regardless of size) and forgets resumed
    /// bytes on retries, so it reads 5% while gigabytes sit on disk.
    private nonisolated static func downloadedBytes(variant: String, repo: String, downloadBase: URL) -> Int64 {
        let fm = FileManager.default
        let repoDir = downloadBase.appendingPathComponent("models").appendingPathComponent(repo)
        var total: Int64 = 0
        for dir in [repoDir.appendingPathComponent(variant),
                    repoDir.appendingPathComponent(".cache/huggingface/download").appendingPathComponent(variant)] {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let file as URL in enumerator {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    private func runDownloadAttempt(modelId: String, variant: String, repo: String, downloadBase: URL) async throws -> URL {
        let modelManager = ModelManager.shared
        let stalled = TranscriptionCancellationFlag()
        let expectedBytes = modelManager.modelSizeBytes(for: modelId)

        let task = Task {
            try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                from: repo,
                progressCallback: { progress in
                    let speed = progress.userInfo[.throughputKey] as? Double
                    Task { @MainActor in
                        if let speed {
                            modelManager.downloadSpeed[modelId] = speed
                        }
                    }
                }
            )
        }
        downloadTasks[modelId] = task
        defer { downloadTasks[modelId] = nil }

        // Byte-based progress and stall detection off disk state
        let watchdog = Task { @MainActor in
            var lastBytes = Self.downloadedBytes(variant: variant, repo: repo, downloadBase: downloadBase)
            var lastGrowth = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                let bytes = Self.downloadedBytes(variant: variant, repo: repo, downloadBase: downloadBase)
                if let expectedBytes, expectedBytes > 0 {
                    modelManager.downloadProgress[modelId] = min(Double(bytes) / Double(expectedBytes), 0.99)
                }
                if bytes > lastBytes {
                    lastBytes = bytes
                    lastGrowth = Date()
                } else if Date().timeIntervalSince(lastGrowth) > 30 {
                    stalled.cancel()
                    task.cancel()
                    break
                }
            }
        }
        defer { watchdog.cancel() }

        do {
            return try await task.value
        } catch {
            // Distinguish watchdog aborts (retry) from user cancellation and
            // real network errors (propagate)
            if stalled.isCancelled {
                throw DownloadStalledError()
            }
            throw error
        }
    }

    /// Removes everything a cancelled download left on disk so orphaned
    /// multi-gigabyte partials don't accumulate invisibly: the files that had
    /// already finished, and the staging area holding the unfinished ones —
    /// which is where the bulk of an interrupted download actually is.
    ///
    /// Not for a download that merely failed or stalled: those keep their
    /// partial files so the next attempt resumes instead of starting over.
    private func cleanupPartialDownload(modelId: String) {
        let modelManager = ModelManager.shared
        // Never remove a model that was previously recorded as fully downloaded
        guard modelManager.cachedModelFolder(for: modelId) == nil,
              let folder = Self.defaultModelFolder(for: modelId, downloadBase: modelManager.downloadBase) else { return }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: Self.stagingDirectory(forModelFolder: folder))
    }
    
    /// Downloads a model without loading it into memory.
    /// Used when the user selects a non-downloaded model from the dropdown.
    public func downloadOnly(modelId: String) async throws {
        let modelManager = ModelManager.shared
        
        guard ModelManager.engine(for: modelId) == .whisperKit,
              let variant = Self.modelVariant(for: modelId) else {
            throw TranscriptionError.unsupportedModel
        }
        // Skip if already downloaded or already downloading
        guard modelManager.cachedModelFolder(for: modelId) == nil else { return }
        guard modelManager.isDownloading[modelId] != true else { return }

        _ = try await downloadModel(
            modelId: modelId,
            variant: variant,
            repo: Self.modelRepo(for: modelId),
            downloadBase: modelManager.downloadBase
        )
    }

    public func loadModel(_ modelName: String) async throws {
        try await initialize(modelId: modelName)
    }
    
    public func unloadModel() {
        // Also invalidates a load that is still in flight (see loadAndInstall)
        unloadGeneration += 1
        whisperKit = nil
        currentModelId = nil
    }

    /// Cancels the in-flight transcription, if any. WhisperKit inference
    /// early-stops via the progress callback returning false.
    public func cancelTranscription() {
        activeCancellationFlag?.cancel()
        activeTranscriptionTask?.cancel()
    }

    /// How the language of a transcription is settled before decoding.
    enum LanguageChoice: Equatable {
        /// Decode in this language.
        case fixed(String)
        /// Nothing fixes the language: detect it from the audio.
        case detectFromAudio
    }

    /// What to decode in when the user asked for `requested` ("auto" or nil
    /// meaning no preference) on `modelId`. The KB and NB models are
    /// fine-tunes for one language each, so for them "auto" has an answer
    /// without listening; only the multilingual OpenAI models need detection.
    nonisolated static func languageChoice(requested: String?, modelId: String) -> LanguageChoice {
        if let requested, !requested.isEmpty, requested != "auto" {
            return .fixed(requested)
        }
        if modelId.hasPrefix("kb_whisper-") { return .fixed("sv") }
        if modelId.hasPrefix("nb_whisper-") { return .fixed("no") }
        return .detectFromAudio
    }

    public func transcribe(fileURL: URL, modelId: String, language: String?) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        let cancelFlag = TranscriptionCancellationFlag()
        activeCancellationFlag = cancelFlag

        // Bounded, newest-wins: see TranscriptionUpdate.streamBufferLimit
        return AsyncThrowingStream(
            TranscriptionUpdate.self,
            bufferingPolicy: .bufferingNewest(TranscriptionUpdate.streamBufferLimit)
        ) { continuation in
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
                            statusMessage = String(format: localized("loading_model_status"), ModelManager.shared.displayName(for: modelId))
                        } else if isAlreadyDownloading {
                            statusMessage = String(format: localized("downloading_model"), ModelManager.shared.displayName(for: modelId))
                        } else {
                            statusMessage = localized("downloading_whisperkit_model")
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
                                    text: String(format: localized("model_optimizing_status"),
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
                        text: localized("initializing_whisperkit"),
                        progress: 0.05,
                        segments: [],
                        isComplete: false
                    ))
                    
                    // Loading audio
                    continuation.yield(TranscriptionUpdate(
                        text: localized("loading_audio_file"),
                        progress: 0.1,
                        segments: [],
                        isComplete: false
                    ))
                    
                    // Resolve the language to decode in. "Auto" has to become a
                    // concrete language before decoding: with a nil language
                    // and the prefill on, WhisperKit detects nothing (its
                    // detectLanguage defaults to !usePrefillPrompt) and
                    // prefills its default language — English.
                    var decodeLanguage: String?
                    var detectLanguagePerWindow = false
                    switch Self.languageChoice(requested: language, modelId: modelId) {
                    case .fixed(let code):
                        decodeLanguage = code
                        self.logger.info("Decoding language: \(code, privacy: .public)")
                    case .detectFromAudio:
                        do {
                            // Detected once, from the first 30 seconds, and
                            // held for the whole file.
                            let detected = try await whisperKit.detectLanguage(audioPath: fileURL.path)
                            decodeLanguage = detected.language
                            self.logger.info("Decoding language: \(detected.language, privacy: .public) (detected from the audio)")
                        } catch {
                            // Leave the choice to the model, window by window.
                            // The prefill stays on, so it still cannot switch
                            // to translating; the other options are forcing
                            // English or dropping the prefill, which lets it.
                            detectLanguagePerWindow = true
                            self.logger.warning("Language detection failed, detecting per window instead: \(error.localizedDescription, privacy: .private)")
                        }
                        try Task.checkCancellation()
                    }

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
                        language: decodeLanguage,
                        usePrefillPrompt: true,
                        // Only when the one-off detection above failed
                        detectLanguage: detectLanguagePerWindow,
                        skipSpecialTokens: true,
                        withoutTimestamps: false,
                        // Always on: word timings power word-level speaker
                        // assignment in the Talare view (~10-20% extra decode
                        // time, essential for meeting transcripts where short
                        // interjections change speakers mid-segment)
                        wordTimestamps: true,
                        // One worker: chunks stream sequentially into the live
                        // preview. Concurrent workers interleave windowIds and
                        // the streamed text appears to be written by several
                        // hands at once.
                        concurrentWorkerCount: 1,
                        chunkingStrategy: .vad
                    )

                    // WhisperKit reports on this run from other threads (see
                    // StreamingCallbackState); the state object collects it.
                    let callbackState = StreamingCallbackState(continuation: continuation)

                    // Transcribe with streaming callback. Returning false from
                    // the callback early-stops WhisperKit inference on cancel.
                    let callback: @Sendable (TranscriptionProgress) -> Bool? = { progress in
                        guard !cancelFlag.isCancelled else { return false }
                        callbackState.handleProgress(progress)
                        return true
                    }

                    // Until the first words are decoded there is no transcript
                    // to show. This is a status (progress below the content
                    // floor), not a placeholder passed off as text.
                    continuation.yield(TranscriptionUpdate(
                        text: localized("transcribing"),
                        progress: 0.12,
                        segments: [],
                        isComplete: false
                    ))

                    // File names are the user's data: not in the public log
                    self.logger.info("Transcription started: \(fileURL.lastPathComponent, privacy: .private) model=\(modelId, privacy: .public)")
                    let transcribeStart = Date()
                    let results = try await StreamingCallbackState.$current.withValue(callbackState) {
                        try await whisperKit.transcribe(
                            audioPath: fileURL.path,
                            decodeOptions: decodeOptions,
                            callback: callback
                        )
                    }
                    // Progress callbacks can still be in flight; from here on
                    // they must not add to the stream.
                    callbackState.finish()
                    self.logger.info("Transcription finished in \(Date().timeIntervalSince(transcribeStart), format: .fixed(precision: 1))s")

                    // If cancelled, don't report the partial output as a
                    // successful, complete transcription.
                    if cancelFlag.isCancelled || Task.isCancelled {
                        throw CancellationError()
                    }

                    // Nor a transcript with a hole in it. WhisperKit leaves a
                    // chunk that failed out of what it returns and mentions it
                    // only in its debug log (updateSeekOffsetsForResults); if
                    // every chunk failed, the result is empty and looks done.
                    if let failure = callbackState.chunkFailure {
                        self.logger.error("\(failure.failedChunks) of \(failure.chunkCount) chunks failed to transcribe: \(failure.error.localizedDescription, privacy: .private)")
                        throw failure.error
                    }

                    // Process final result. VAD chunking returns one
                    // TranscriptionResult per chunk — merge them all; taking
                    // only the first would drop most of the transcription.
                    let merged = TranscriptionUtilities.mergeTranscriptionResults(results)
                    let fullText = merged.segments
                        .map { strippingSpecialTokens($0.text).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")

                    let finalSegments = merged.segments.map { segment in
                        TranscriptionSegmentData(
                            start: Double(segment.start),
                            end: Double(segment.end),
                            text: strippingSpecialTokens(segment.text).trimmingCharacters(in: .whitespaces),
                            words: segment.words?.map { word in
                                WordTimestamp(
                                    word: word.word,
                                    start: Double(word.start),
                                    end: Double(word.end),
                                    confidence: word.probability
                                )
                            }
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

/// Removes `<|...|>` special-token markers from Whisper output. skipSpecialTokens
/// covers the standard vocabulary but misses model-specific tokens like
/// NB Whisper's `<|nocaptions|>`, which otherwise leak into visible text.
private func strippingSpecialTokens(_ text: String) -> String {
    text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
}

// Thread-safe cancellation flag shared between the producer task, the stream's
// onTermination handler, and WhisperKit's progress callback (which may run
// outside the producer task's context, where Task.isCancelled is unreliable).
private final class TranscriptionCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

/// Everything WhisperKit reports about one transcription run while it is
/// running: the text decoded so far (streamed to the UI), how far into the
/// audio the decoder is, and whether any chunk failed.
///
/// All of it is guarded by a lock. WhisperKit does not call the progress
/// callback from its decoding loop but from a detached task per decoded token
/// (TextDecoder.decodeText), so calls overlap each other, can arrive out of
/// order, and can trail in after the transcription has returned.
final class StreamingCallbackState: @unchecked Sendable {
    /// The run the current task is transcribing for. WhisperKit hands the
    /// per-chunk results to no one, so `TranscribeWhisperKit` picks them up
    /// where they are produced and needs to know whose they are; a task-local
    /// keeps runs apart without assuming there is only one at a time.
    @TaskLocal static var current: StreamingCallbackState?

    /// Minimum time between two live-text updates. Each one carries the
    /// whole transcript so far, so one per token would copy a growing string
    /// dozens of times a second.
    static let updateInterval: TimeInterval = 0.2

    /// How many tokens an update may trail the newest one seen for its window
    /// and still be taken for a late arrival. A larger drop means the window
    /// is being decoded again from the start (temperature fallback), which is
    /// newer, not older.
    static let reorderTolerance = 8

    private let continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    private let lock = NSLock()

    /// Text of the windows the decoder has moved past.
    private var finishedText = ""
    private var currentWindowId = -1
    private var currentWindowText = ""
    private var currentWindowTokenCount = 0
    private var lastYieldedText = ""
    private var lastYieldTime = Date.distantPast
    private var isFinished = false

    /// Where each VAD chunk starts in the audio, in samples, and the length
    /// of the audio they cover. Empty for audio that fits in one window.
    private var chunkOffsets: [Int] = []
    private var totalSamples = 0

    private var chunkCount = 0
    private var failedChunks = 0
    private var firstFailure: Error?

    init(continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation) {
        self.continuation = continuation
    }

    func handleProgress(_ progress: TranscriptionProgress) {
        update(windowId: progress.windowId, tokenCount: progress.tokens.count, text: progress.text, now: Date())
    }

    /// Takes in one progress report. `tokenCount` orders reports within a
    /// window: it only grows while a window is being decoded.
    func update(windowId: Int, tokenCount: Int, text: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }

        // With one worker the windows are decoded in order, so a report for
        // an earlier window is a straggler.
        guard !isFinished, windowId >= currentWindowId else { return }

        if windowId > currentWindowId {
            if !currentWindowText.isEmpty {
                finishedText += finishedText.isEmpty ? currentWindowText : " " + currentWindowText
            }
            currentWindowId = windowId
            currentWindowText = ""
            currentWindowTokenCount = 0
        } else if tokenCount <= currentWindowTokenCount,
                  currentWindowTokenCount - tokenCount <= Self.reorderTolerance {
            // Overtaken by a newer report for this window: showing it would
            // make the live text step backwards.
            return
        }
        currentWindowTokenCount = tokenCount
        currentWindowText = strippingSpecialTokens(text).trimmingCharacters(in: .whitespaces)

        // Yield only when there is something new to show and the last update
        // is old enough. Nothing is lost by skipping: the next report, or the
        // final result, carries the same text and more.
        guard now.timeIntervalSince(lastYieldTime) >= Self.updateInterval else { return }
        let fullText: String
        if finishedText.isEmpty {
            fullText = currentWindowText
        } else if currentWindowText.isEmpty {
            fullText = finishedText
        } else {
            fullText = finishedText + " " + currentWindowText
        }
        guard !fullText.isEmpty, fullText != lastYieldedText else { return }
        lastYieldTime = now
        lastYieldedText = fullText

        continuation.yield(TranscriptionUpdate(
            text: fullText,
            progress: contentProgress,
            segments: [],
            isComplete: false
        ))
    }

    /// How far the decoder is through the audio, mapped into the band the
    /// consumers reserve for content (below it they expect status messages;
    /// 1.0 belongs to the final result). The position is the start of the
    /// chunk WhisperKit says it is decoding, so it only moves when audio has
    /// actually been transcribed. Call with the lock held.
    private var contentProgress: Double {
        let floor = TranscriptionUpdate.contentProgressFloor
        guard totalSamples > 0, chunkOffsets.indices.contains(currentWindowId) else { return floor }
        let fraction = Double(chunkOffsets[currentWindowId]) / Double(totalSamples)
        return floor + (0.95 - floor) * min(max(fraction, 0), 1)
    }

    /// Records how WhisperKit split the audio: the sample offset and length
    /// of each chunk, in decoding order. The progress callback's window id is
    /// the index of the chunk being decoded.
    func setChunkLayout(offsets: [Int], lengths: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        chunkOffsets = offsets
        totalSamples = zip(offsets, lengths).map { $0 + $1 }.max() ?? 0
    }

    /// Records the outcome of every chunk. Generic so the caller's result
    /// type does not have to be spelled here.
    func recordChunkResults<Success>(_ results: [Result<Success, Error>]) {
        lock.lock()
        defer { lock.unlock() }
        chunkCount += results.count
        for case .failure(let error) in results {
            failedChunks += 1
            if firstFailure == nil, !(error is CancellationError) {
                firstFailure = error
            }
        }
    }

    /// Set when at least one chunk failed: the first failure that is not a
    /// cancellation, or a cancellation if those are all there is.
    var chunkFailure: (error: Error, failedChunks: Int, chunkCount: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard failedChunks > 0 else { return nil }
        return (firstFailure ?? CancellationError(), failedChunks, chunkCount)
    }

    /// Stops live updates. Called when the transcription has returned, so a
    /// progress report that is still in flight cannot follow the final result.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
    }
}

/// WhisperKit with the hooks this app needs and the stock class does not
/// offer. Everything else — loading, chunking, decoding — is inherited as is.
final class TranscribeWhisperKit: WhisperKit {

    /// Hands the outcome of every chunk to the run it belongs to.
    ///
    /// For audio longer than one window, `transcribe` splits it into VAD
    /// chunks and sends them here; of what comes back it keeps the successes
    /// and drops the failures. This is the one place where both are visible.
    /// The transcription itself is untouched: same call, same arguments.
    ///
    /// The result type is spelled with a module selector because the plain
    /// name is this package's own `TranscriptionResult`, and
    /// `WhisperKit.TranscriptionResult` would look for it inside the class.
    override func transcribeWithOptions(
        audioArrays: [[Float]],
        decodeOptionsArray: [DecodingOptions?] = [nil],
        seekOffsets: [Int]? = nil,
        callback: TranscriptionCallback? = nil
    ) async -> [Result<[WhisperKit::TranscriptionResult], Swift.Error>] {
        let run = StreamingCallbackState.current
        if let seekOffsets, seekOffsets.count == audioArrays.count {
            run?.setChunkLayout(offsets: seekOffsets, lengths: audioArrays.map(\.count))
        }
        let results = await super.transcribeWithOptions(
            audioArrays: audioArrays,
            decodeOptionsArray: decodeOptionsArray,
            seekOffsets: seekOffsets,
            callback: callback
        )
        run?.recordChunkResults(results)
        return results
    }

    /// Refuses to fetch a tokenizer in local-only mode.
    ///
    /// WhisperKit resolves the tokenizer here, after the CoreML models are
    /// loaded, and falls back to downloading it from the Hub whenever it
    /// cannot load one from disk (ModelUtilities.loadTokenizer) — regardless
    /// of `download: false`. In local-only mode that request must not
    /// happen, so the same lookup is done first and a load that would need
    /// the network fails with an error that says why.
    override func loadTokenizerIfNeeded() async throws {
        // Without the dimensions WhisperKit throws before it looks anywhere
        if tokenizer == nil,
           UserDefaults.standard.bool(forKey: "localOnlyMode"),
           let vocabularySize = textDecoder.logitsSize,
           let encoderDimension = audioEncoder.embedSize {
            let repoId = WhisperTokenizerFiles.repoId(vocabularySize: vocabularySize, encoderDimension: encoderDimension)
            let localFolder = WhisperTokenizerFiles.localFolder(
                repoId: repoId,
                tokenizerBase: tokenizerFolder,
                modelFolder: modelFolder
            )
            // WhisperKit also goes to the Hub when the files are there but
            // do not load, so "present" has to mean "loads": try exactly the
            // call it will make.
            guard let localFolder,
                  (try? await AutoTokenizerWrapper.from(
                      modelFolder: localFolder,
                      hubApi: HubApiWrapper(downloadBase: tokenizerFolder)
                  )) != nil else {
                throw WhisperKitService.ModelDownloadError.tokenizerNeedsNetwork
            }
        }
        try await super.loadTokenizerIfNeeded()
    }
}

/// Which tokenizer WhisperKit wants for a model, and where it looks for it.
///
/// WhisperKit keeps this to itself (ModelUtilities.detectVariant,
/// tokenizerNameForVariant and loadTokenizer are internal or do the lookup
/// and the download in one step), so the rules are mirrored here as of
/// argmax-oss-swift 1.0.0. They are what lets the app fetch the tokenizer
/// together with the model, and tell without a request whether a load would
/// need the network.
enum WhisperTokenizerFiles {
    /// What WhisperKit fetches from a tokenizer repository
    /// (LanguageModelConfigurationFromHub.loadConfig), minus the chat
    /// templates no Whisper repository has.
    static let downloadedFiles = ["config.json", "tokenizer_config.json", "tokenizer.json"]

    /// The repository holding the tokenizer for a model of these dimensions.
    /// Fine-tunes (KB, NB) use the tokenizer of the OpenAI model they are
    /// built on, which the dimensions identify.
    static func repoId(vocabularySize: Int, encoderDimension: Int) -> String {
        let name: String
        switch vocabularySize {
        case 51865: // multilingual
            switch encoderDimension {
            case 384: name = "tiny"
            case 512: name = "base"
            case 768: name = "small"
            case 1024: name = "medium"
            case 1280: name = "large-v2"
            default: name = "base"
            }
        case 51864: // English-only
            switch encoderDimension {
            case 384: name = "tiny.en"
            case 512: name = "base.en"
            case 768: name = "small.en"
            case 1024: name = "medium.en"
            default: name = "base.en"
            }
        case 51866: // large-v3 has one more language token
            name = "large-v3"
        default:
            name = "base"
        }
        return "openai/whisper-\(name)"
    }

    /// The tokenizer repository for a downloaded model, read from the Hugging
    /// Face `config.json` its folder carries. Nil when that file does not
    /// state the model's dimensions.
    static func repoId(forModelFolder folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vocabularySize = config["vocab_size"] as? Int,
              let encoderDimension = config["d_model"] as? Int else { return nil }
        return repoId(vocabularySize: vocabularySize, encoderDimension: encoderDimension)
    }

    /// The folder WhisperKit will load the tokenizer from, or nil when it
    /// will download it instead.
    ///
    /// It takes the first of its search paths that has a `tokenizer.json`,
    /// and loading from there needs a `tokenizer_config.json` beside it — if
    /// that is missing it does not try the next path, it goes to the Hub.
    static func localFolder(repoId: String, tokenizerBase: URL?, modelFolder: URL?) -> URL? {
        let repo = HubApiWrapper.Repo(id: repoId)
        var searchPaths = [HubApiWrapper(downloadBase: tokenizerBase).localRepoLocation(repo)]
        if let tokenizerBase {
            searchPaths.append(tokenizerBase)
        }
        if let modelFolder {
            searchPaths.append(modelFolder)
            searchPaths.append(HubApiWrapper(downloadBase: modelFolder).localRepoLocation(repo))
        }

        let fm = FileManager.default
        guard let folder = searchPaths.first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent("tokenizer.json").path)
        }) else { return nil }
        return fm.fileExists(atPath: folder.appendingPathComponent("tokenizer_config.json").path) ? folder : nil
    }
}

extension TranscriptionError {
    public static let initializationTimeout = TranscriptionError.modelNotFound
}
