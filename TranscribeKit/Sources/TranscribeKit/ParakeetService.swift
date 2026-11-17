import Foundation
import AVFoundation
import FluidAudio
import os

/// Transcription with Parakeet-family CoreML models (Klang's Pianissimo for
/// Swedish, NVIDIA Parakeet v3 for 25 European languages), run on the Neural
/// Engine through FluidAudio.
///
/// These models are an order of magnitude faster than Whisper, which is what
/// makes `LiveTranscriptionSession` possible. They decode a fixed 15-second
/// window; FluidAudio splits longer audio and merges the seams.
///
/// This is the only file besides `LiveTranscriptionSession` that imports
/// FluidAudio: its public names (`WordTiming`, `Language`, …) collide with
/// WhisperKit's, so the two runtimes must never meet in one file.
@MainActor
public final class ParakeetService {
    /// Shared instance: one loaded model serves batch and live transcription.
    public static let shared = ParakeetService()

    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "Parakeet")

    private var manager: AsrManager?
    private var loadedModelId: String?
    private var loading: (modelId: String, task: Task<AsrManager, Error>)?
    private var downloads: [String: Task<Void, Error>] = [:]

    private init() {}

    public var currentModel: String? { loadedModelId }

    // MARK: - Download

    /// Downloads a model without loading it. Concurrent calls for the same
    /// model share one transfer.
    public func downloadOnly(modelId: String) async throws {
        guard let spec = ParakeetModelSpec.spec(for: modelId) else {
            throw TranscriptionError.unsupportedModel
        }
        let modelManager = ModelManager.shared
        guard modelManager.cachedModelFolder(for: modelId) == nil else { return }
        if let inFlight = downloads[modelId] {
            try await inFlight.value
            return
        }

        let destination = modelManager.parakeetModelFolder(for: modelId)
        modelManager.isDownloading[modelId] = true
        modelManager.downloadProgress[modelId] = 0

        let task = Task {
            try await HuggingFaceDownloader.download(
                HuggingFaceDownloader.Snapshot(repo: spec.repo, revision: spec.revision, entries: spec.entries),
                to: destination
            ) { progress in
                Task { @MainActor in
                    let modelManager = ModelManager.shared
                    // Late callbacks must not reopen a finished or cancelled download
                    guard modelManager.isDownloading[modelId] == true else { return }
                    modelManager.downloadProgress[modelId] = min(progress.fraction, 0.99)
                    modelManager.downloadSpeed[modelId] = progress.bytesPerSecond
                }
            }
        }
        downloads[modelId] = task

        do {
            try await task.value
            downloads[modelId] = nil
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress[modelId] = 1.0
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            modelManager.saveModelFolderPath(destination.path, for: modelId)
            logger.info("Downloaded \(modelId, privacy: .public)")
        } catch {
            downloads[modelId] = nil
            modelManager.isDownloading[modelId] = false
            modelManager.downloadProgress.removeValue(forKey: modelId)
            modelManager.downloadSpeed.removeValue(forKey: modelId)
            if error is CancellationError {
                // A cancelled download is abandoned; a failed one keeps its
                // partial files so the next attempt resumes.
                try? FileManager.default.removeItem(at: HuggingFaceDownloader.stagingDirectory(for: destination))
            }
            throw error
        }
    }

    public func cancelDownload(modelId: String) {
        downloads[modelId]?.cancel()
    }

    // MARK: - Loading

    /// Loads the user's selected model at launch if it is a downloaded
    /// Parakeet-family model, so the first transcription starts immediately.
    public func prewarm(modelId: String) {
        guard ParakeetModelSpec.spec(for: modelId) != nil,
              ModelManager.shared.cachedModelFolder(for: modelId) != nil else { return }
        Task { @MainActor in
            _ = try? await self.loadModel(modelId)
        }
    }

    /// Returns the loaded model, loading (and if needed downloading) it first.
    /// Concurrent requests for the same model share one load.
    @discardableResult
    func loadModel(_ modelId: String) async throws -> AsrManager {
        guard ParakeetModelSpec.spec(for: modelId) != nil else {
            throw TranscriptionError.unsupportedModel
        }
        while true {
            if let manager, loadedModelId == modelId { return manager }
            guard let inFlight = loading else { break }
            if inFlight.modelId == modelId {
                return try await inFlight.task.value
            }
            // Another model is mid-load: let it settle, then re-evaluate
            _ = try? await inFlight.task.value
        }

        if ModelManager.shared.cachedModelFolder(for: modelId) == nil {
            try await downloadOnly(modelId: modelId)
            // The download suspended: someone else may have loaded it meanwhile
            if let manager, loadedModelId == modelId { return manager }
        }
        guard let folder = ModelManager.shared.cachedModelFolder(for: modelId) else {
            throw TranscriptionError.modelNotFound
        }

        let start = Date()
        let task = Task<AsrManager, Error> {
            // CoreML load (and first-time Neural Engine compile) blocks for
            // seconds; keep it off the main actor.
            let models = try await Task.detached(priority: .userInitiated) {
                try AsrModels.loadLocal(from: URL(fileURLWithPath: folder), version: .v3)
            }.value
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = (modelId, task)
        defer {
            if loading?.modelId == modelId { loading = nil }
        }

        let loaded = try await task.value
        if let previous = manager {
            await previous.cleanup()
        }
        manager = loaded
        loadedModelId = modelId
        logger.info("Loaded \(modelId, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
        return loaded
    }

    /// Loads `modelId` so the next transcription or live session starts at once.
    public func preload(modelId: String) async throws {
        try await loadModel(modelId)
    }

    public func unloadModel() {
        let previous = manager
        manager = nil
        loadedModelId = nil
        Task { await previous?.cleanup() }
    }

    // MARK: - Batch transcription

    /// Transcribes a file, streaming status, a growing text preview and
    /// finally the timed segments — the same update shape WhisperKitService
    /// produces, so views don't care which engine ran.
    ///
    /// `fileURL` must be readable by `AVAudioFile` (the caller extracts audio
    /// from video containers first).
    public func transcribe(fileURL: URL, modelId: String, language: String?) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream(TranscriptionUpdate.self) { continuation in
            let task = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    if self.manager == nil || self.loadedModelId != modelId {
                        let name = ModelManager.shared.displayName(for: modelId)
                        let isCached = ModelManager.shared.cachedModelFolder(for: modelId) != nil
                        continuation.yield(TranscriptionUpdate(
                            text: String(format: localized(isCached ? "loading_model_status" : "downloading_model"), name),
                            progress: 0.01,
                            segments: [],
                            isComplete: false
                        ))
                    }
                    let manager = try await self.loadModel(modelId)
                    try Task.checkCancellation()

                    continuation.yield(TranscriptionUpdate(
                        text: localized("loading_audio_file"),
                        progress: 0.1,
                        segments: [],
                        isComplete: false
                    ))

                    // Long files decode as overlapping windows on several
                    // workers; show the finished run of windows as it grows.
                    let preview = WindowPreview()
                    await manager.setWindowHandler { window in
                        guard let text = preview.add(window) else { return }
                        continuation.yield(TranscriptionUpdate(
                            text: text,
                            progress: preview.displayProgress,
                            segments: [],
                            isComplete: false
                        ))
                    }

                    self.logger.info("Transcription started: \(fileURL.lastPathComponent, privacy: .public) model=\(modelId, privacy: .public)")
                    let start = Date()
                    var decoderState = TdtDecoderState.make()
                    let result: ASRResult
                    do {
                        result = try await manager.transcribe(
                            fileURL,
                            decoderState: &decoderState,
                            language: Self.languageHint(code: language, modelId: modelId)
                        )
                    } catch {
                        await manager.setWindowHandler(nil)
                        throw error
                    }
                    await manager.setWindowHandler(nil)
                    try Task.checkCancellation()
                    self.logger.info("Transcription finished in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s (\(result.rtfx, format: .fixed(precision: 0))x real time)")

                    let words = Self.words(from: result)
                    let segments = TranscriptSegmenter.segments(from: words)
                    let text = segments.isEmpty
                        ? result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        : segments.map(\.text).joined(separator: " ")

                    continuation.yield(TranscriptionUpdate(
                        text: text,
                        progress: 1.0,
                        segments: segments,
                        isComplete: true
                    ))
                    continuation.finish()
                } catch let error as ASRError {
                    // Audio shorter than the model's minimum is an empty
                    // transcript, not a failure the user can act on.
                    if case .invalidAudioData = error {
                        continuation.yield(TranscriptionUpdate(text: "", progress: 1.0, segments: [], isComplete: true))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Live transcription

    /// Starts a live session on `modelId`, loading the model if needed.
    public func makeLiveSession(modelId: String, language: String?) async throws -> LiveTranscriptionSession {
        let manager = try await loadModel(modelId)
        return LiveTranscriptionSession(
            manager: manager,
            language: Self.languageHint(code: language, modelId: modelId)
        )
    }

    /// The model to use for live text while recording: the selected model if
    /// it is Parakeet-family, otherwise an already-downloaded one that covers
    /// the language (so live text also works when Whisper does the final pass).
    public static func liveModelId(selectedModel: String, languageCode: String) -> String? {
        let modelManager = ModelManager.shared
        if ParakeetModelSpec.spec(for: selectedModel) != nil {
            return modelManager.isModelDownloaded(selectedModel) ? selectedModel : nil
        }
        // A Swedish-tuned Whisper model implies Swedish speech even on "auto"
        let effectiveLanguage = languageCode == "auto" && selectedModel.hasPrefix("kb_whisper-") ? "sv" : languageCode
        let candidates = ParakeetModelSpec.all
            .filter { modelManager.isModelDownloaded($0.id) }
            .filter { effectiveLanguage == "auto" || $0.languageCodes.contains(effectiveLanguage) }
        // Prefer the most specialised model (fewest languages)
        return candidates.min { $0.languageCodes.count < $1.languageCodes.count }?.id
    }

    // MARK: - Helpers

    /// Parakeet has no language conditioning; the hint only keeps the decoder
    /// in the right script (it stops Cyrillic leaking into Latin-script
    /// speech on short windows). Unknown codes mean "no hint".
    static func languageHint(code: String?, modelId: String) -> Language? {
        if let spec = ParakeetModelSpec.spec(for: modelId), spec.languageCodes.count == 1,
           let only = spec.languageCodes.first {
            return Language(rawValue: only)
        }
        guard let code, code != "auto" else { return nil }
        return Language(rawValue: code)
    }

    static func words(from result: ASRResult) -> [WordTimestamp] {
        guard let timings = result.tokenTimings, !timings.isEmpty else { return [] }
        // Mean token confidence per word, matched by time span
        var tokenIndex = 0
        return buildWordTimings(from: timings).map { word in
            var sum: Float = 0
            var count: Float = 0
            while tokenIndex < timings.count, timings[tokenIndex].endTime <= word.endTime + 0.0001 {
                if timings[tokenIndex].startTime >= word.startTime - 0.0001 {
                    sum += timings[tokenIndex].confidence
                    count += 1
                }
                tokenIndex += 1
            }
            return WordTimestamp(
                word: word.word,
                start: word.startTime,
                end: word.endTime,
                confidence: count > 0 ? sum / count : result.confidence
            )
        }
    }
}

/// Collects finished windows of a long transcription (they complete out of
/// order) and exposes the text of the contiguous run from the start, so the
/// preview only ever grows forward.
private final class WindowPreview: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [Int: String] = [:]
    private var contiguous = 0
    private var joined = ""
    private var windowCount = 1

    /// Returns the new preview text when this window extended the run.
    func add(_ window: AsrManager.WindowProgress) -> String? {
        lock.lock()
        defer { lock.unlock() }
        windowCount = max(window.windowCount, 1)
        texts[window.index] = window.text
        var grew = false
        while let next = texts[contiguous] {
            let trimmed = next.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                joined += joined.isEmpty ? trimmed : " " + trimmed
            }
            texts[contiguous] = nil
            contiguous += 1
            grew = true
        }
        return grew && !joined.isEmpty ? joined : nil
    }

    /// Progress for the UI: always past the "status message" band (< 0.15).
    var displayProgress: Double {
        lock.lock()
        defer { lock.unlock() }
        return 0.15 + 0.8 * Double(contiguous) / Double(windowCount)
    }
}

/// Groups timed words into readable, subtitle-sized segments.
public enum TranscriptSegmenter {
    /// Splits at sentence ends and long pauses, and caps a segment's length
    /// so an unpunctuated monologue still yields usable timestamps.
    public static func segments(
        from words: [WordTimestamp],
        pauseSplit: Double = 1.0,
        maxWords: Int = 40,
        maxDuration: Double = 20
    ) -> [TranscriptionSegmentData] {
        var segments: [TranscriptionSegmentData] = []
        var current: [WordTimestamp] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(TranscriptionSegmentData(
                start: first.start,
                end: last.end,
                text: current.map(\.word).joined(separator: " "),
                words: current
            ))
            current = []
        }

        for word in words {
            if let previous = current.last, let first = current.first {
                let endsSentence = previous.word.last.map { ".!?…".contains($0) } ?? false
                let longPause = word.start - previous.end >= pauseSplit
                let tooLong = current.count >= maxWords || word.end - first.start > maxDuration
                if endsSentence || longPause || tooLong {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        return segments
    }
}
