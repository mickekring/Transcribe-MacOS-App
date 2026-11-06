import Foundation
import AVFoundation
import CoreML
import CryptoKit
import FluidAudio
import os

/// On-device transcription with Klang Pianissimo — a Swedish fine-tune of
/// NVIDIA Parakeet TDT 0.6B v3 (FastConformer encoder + TDT decoder). It is
/// not a Whisper model, so it runs on FluidAudio's Parakeet pipeline instead
/// of WhisperKit. WhisperKitService delegates every call for
/// `PianissimoService.modelId` here, so the rest of the app treats it like
/// any other local model.
///
/// Weights: the CoreML conversion at `markstrom/pianissimo-sv-coreml`, pinned
/// to a revision and verified file-by-file against SHA-256 checksums. The
/// `.mlpackage`s are compiled on this machine after download, as the
/// conversion's README requires.
@MainActor
public final class PianissimoService {
    public static let shared = PianissimoService()

    public static let modelId = "klang_pianissimo-sv"

    public static func handles(_ modelId: String) -> Bool {
        modelId == Self.modelId
    }

    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "Pianissimo")

    private static let repo = "markstrom/pianissimo-sv-coreml"
    private static let revision = "dd578628d1ae6577b4672221b99fff59112ff5b4"

    /// (path in repo, size in bytes, sha256) — from the conversion's manifest.json
    /// at `revision`. Hardcoded so a changed remote file can never be loaded.
    private static let files: [(path: String, size: Int64, sha256: String)] = [
        ("Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", 11811, "4a36039f091573251bd8bcb55e8f5fa6dc3bad32052d825b1e3b2a3840879990"),
        ("Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 23604992, "9e34a5cc5da3477cf0e49126f55d4754a6a332b5df52a22812d6ddbd84af0e39"),
        ("Decoder.mlpackage/Manifest.json", 617, "99e8049015d297e58291cfe279c832f01e88959ca91894be939753b19f694827"),
        ("Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", 677050, "9c9e8a95b18b35142f00ac3c8c186c669057f7ca4a097b2e463c99486eb8eeb8"),
        ("Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 649181632, "e9623b969e8f31ba12bfbec7cdcdacb3bfb74e5a3a9bd3a812e4a942c1b1b9ed"),
        ("Encoder.mlpackage/Manifest.json", 617, "6d235c39782d2e839142f0df9a6fc3096a6258da05f8be1c1d95547d936cf619"),
        ("JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel", 10827, "af1b876c8677cc8c6676573801038ce6da4972eba4817b1caa2eb09b9ff5ed32"),
        ("JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 12642764, "1f841daf3a6ce483ac136cd7a5e48d6071543e7c5eddcbba4525bda74695cb61"),
        ("JointDecisionv3.mlpackage/Manifest.json", 617, "42ab119e793f459e4a8d4a86f77714f093a54ebea55a14786981962985e8121d"),
        ("Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel", 17913, "44426745838b32d86e0de13054eea2b7c4439e95dadef0bcfa528bdfc93eb630"),
        ("Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 1953088, "c69139820fc62c199f92c83d2c97458f8aaff337e5026abd9606ff03ba52b8e1"),
        ("Preprocessor.mlpackage/Manifest.json", 617, "caffd54a12af3df9bb673f100239919e1047ece8c4035f75819f4adc1d71b6a9"),
        ("parakeet_vocab.json", 151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    private static let components = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    private static let vocabularyFile = "parakeet_vocab.json"

    public static var totalDownloadBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    private var asrManager: AsrManager?
    /// Loaded CoreML components, shared with live (sliding-window) sessions
    private var asrModels: AsrModels?
    private var loadTask: Task<(AsrManager, AsrModels), Error>?
    private var downloadTask: Task<URL, Error>?
    private var activeTranscriptionTask: Task<Void, Never>?

    private init() {}

    // MARK: - Storage

    /// Final folder holding the compiled `.mlmodelc` components + vocabulary.
    private var modelFolder: URL {
        ModelManager.shared.modelsDirectory
            .appendingPathComponent("Pianissimo")
            .appendingPathComponent("pianissimo-sv")
    }

    private var stagingFolder: URL {
        ModelManager.shared.modelsDirectory
            .appendingPathComponent("Pianissimo")
            .appendingPathComponent(".download")
    }

    static func folderIsComplete(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(vocabularyFile).path) else { return false }
        for component in components {
            let compiled = folder.appendingPathComponent("\(component).mlmodelc")
            guard fm.fileExists(atPath: compiled.appendingPathComponent("coremldata.bin").path) else { return false }
        }
        return true
    }

    // MARK: - Download

    /// Downloads, verifies and compiles the model without loading it.
    public func downloadOnly() async throws {
        let modelManager = ModelManager.shared
        guard modelManager.cachedModelFolder(for: Self.modelId) == nil else { return }
        _ = try await ensureDownloaded()
    }

    public func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Returns the installed model folder, downloading it first if needed.
    /// Concurrent callers share one download.
    private func ensureDownloaded() async throws -> URL {
        let modelManager = ModelManager.shared
        if let cached = modelManager.cachedModelFolder(for: Self.modelId),
           Self.folderIsComplete(URL(fileURLWithPath: cached)) {
            return URL(fileURLWithPath: cached)
        }
        if let downloadTask {
            return try await downloadTask.value
        }

        guard !UserDefaults.standard.bool(forKey: "localOnlyMode") else {
            throw PianissimoError.localOnlyMode
        }

        modelManager.isDownloading[Self.modelId] = true
        modelManager.downloadProgress[Self.modelId] = 0

        let task = Task { try await self.performDownload() }
        downloadTask = task
        defer {
            downloadTask = nil
            modelManager.isDownloading[Self.modelId] = false
            modelManager.downloadSpeed.removeValue(forKey: Self.modelId)
        }

        do {
            let folder = try await task.value
            modelManager.downloadProgress[Self.modelId] = 1.0
            modelManager.saveModelFolderPath(folder.path, for: Self.modelId)
            return folder
        } catch {
            modelManager.downloadProgress.removeValue(forKey: Self.modelId)
            try? FileManager.default.removeItem(at: stagingFolder)
            throw error
        }
    }

    private func performDownload() async throws -> URL {
        let fm = FileManager.default
        let staging = stagingFolder
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        logger.info("Downloading Pianissimo from \(Self.repo, privacy: .public)@\(Self.revision, privacy: .public)")

        let total = Self.totalDownloadBytes
        var completed: Int64 = 0
        let modelManager = ModelManager.shared
        let modelId = Self.modelId

        for file in Self.files {
            try Task.checkCancellation()
            let remote = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/\(file.path)")!
            let destination = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            let base = completed
            let downloaded = try await FileDownloader.download(from: remote) { bytes, speed in
                Task { @MainActor in
                    modelManager.downloadProgress[modelId] = min(Double(base + bytes) / Double(total) * 0.95, 0.95)
                    if let speed { modelManager.downloadSpeed[modelId] = speed }
                }
            }
            try fm.moveItem(at: downloaded, to: destination)

            let hash = try await Task.detached { try Self.sha256(of: destination) }.value
            guard hash == file.sha256 else {
                logger.error("Checksum mismatch for \(file.path, privacy: .public)")
                throw PianissimoError.checksumMismatch(file.path)
            }
            completed += file.size
        }

        // Compile each package for this machine, then install atomically
        let installing = staging.appendingPathComponent("installed")
        try fm.createDirectory(at: installing, withIntermediateDirectories: true)
        for component in Self.components {
            try Task.checkCancellation()
            let package = staging.appendingPathComponent("\(component).mlpackage")
            let compiled = try await MLModel.compileModel(at: package)
            try fm.moveItem(at: compiled, to: installing.appendingPathComponent("\(component).mlmodelc"))
        }
        try fm.copyItem(
            at: staging.appendingPathComponent(Self.vocabularyFile),
            to: installing.appendingPathComponent(Self.vocabularyFile)
        )

        let final = modelFolder
        try? fm.removeItem(at: final)
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: installing, to: final)
        try? fm.removeItem(at: staging)

        guard Self.folderIsComplete(final) else { throw PianissimoError.incompleteInstall }
        logger.info("Pianissimo installed at \(final.path, privacy: .public)")
        return final
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Loading

    public var isLoaded: Bool { asrManager != nil }

    /// Downloads if needed and loads the model. Concurrent calls coalesce.
    public func initialize() async throws {
        _ = try await loadedManager()
    }

    public func unload() {
        loadTask?.cancel()
        loadTask = nil
        asrManager = nil
        asrModels = nil
    }

    private func loadedManager() async throws -> AsrManager {
        try await loaded().0
    }

    /// The loaded models, downloading/loading first if needed. Used by
    /// `LiveTranscriber` so live and file transcription share one copy.
    func loadedModels() async throws -> AsrModels {
        try await loaded().1
    }

    private func loaded() async throws -> (AsrManager, AsrModels) {
        if let asrManager, let asrModels { return (asrManager, asrModels) }
        if let loadTask { return try await loadTask.value }

        let task = Task { () throws -> (AsrManager, AsrModels) in
            let folder = try await self.ensureDownloaded()
            do {
                return try await Self.load(from: folder)
            } catch {
                // A corrupt install would otherwise fail forever — drop it
                // so the next attempt re-downloads.
                self.logger.error("Pianissimo failed to load: \(error.localizedDescription, privacy: .public)")
                ModelManager.shared.deleteModel(Self.modelId)
                throw error
            }
        }
        loadTask = task
        defer { loadTask = nil }

        let loaded = try await task.value
        asrManager = loaded.0
        asrModels = loaded.1
        return loaded
    }

    private nonisolated static func load(from folder: URL) async throws -> (AsrManager, AsrModels) {
        let models = try AsrModels.loadLocal(from: folder, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return (manager, models)
    }

    // MARK: - Transcription

    public func cancelTranscription() {
        activeTranscriptionTask?.cancel()
    }

    /// Same streaming contract as `WhisperKitService.transcribe`: updates
    /// below 0.15 progress are status messages, the final update carries the
    /// full text and segments with word timings (used by diarization).
    /// Pianissimo is Swedish-only, so the selected language is not used.
    public func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    if self.asrManager == nil {
                        let downloaded = ModelManager.shared.cachedModelFolder(for: Self.modelId) != nil
                        let name = ModelManager.shared.displayName(for: Self.modelId)
                        continuation.yield(TranscriptionUpdate(
                            text: String(format: localized(downloaded ? "loading_model_status" : "downloading_model"), name),
                            progress: 0.05,
                            segments: [],
                            isComplete: false
                        ))
                    }
                    let manager = try await self.loadedManager()
                    try Task.checkCancellation()

                    continuation.yield(TranscriptionUpdate(
                        text: localized("transcribing"),
                        progress: 0.1,
                        segments: [],
                        isComplete: false
                    ))

                    // Inference progress (emitted for audio longer than ~15 s)
                    let progressStream = await manager.transcriptionProgressStream
                    let progressTask = Task {
                        for try await fraction in progressStream {
                            continuation.yield(TranscriptionUpdate(
                                text: "",
                                progress: 0.1 + fraction * 0.04,
                                segments: [],
                                isComplete: false
                            ))
                        }
                    }
                    defer { progressTask.cancel() }

                    var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                    let result = try await manager.transcribe(fileURL, decoderState: &decoderState, language: .swedish)
                    try Task.checkCancellation()

                    let segments = Self.segments(from: result)
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
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.activeTranscriptionTask = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Groups word timings into sentence-like segments: a segment ends after
    /// sentence punctuation, at a pause of a second or more, or after ~30 s.
    nonisolated static func segments(from result: ASRResult) -> [TranscriptionSegmentData] {
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [TranscriptionSegmentData(start: 0, end: result.duration, text: text, words: nil)]
        }

        var segments: [TranscriptionSegmentData] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(TranscriptionSegmentData(
                start: first.startTime,
                end: last.endTime,
                text: current.map(\.word).joined(separator: " "),
                words: current.map { WordTimestamp(word: $0.word, start: $0.startTime, end: $0.endTime, confidence: 1.0) }
            ))
            current = []
        }

        for word in words {
            if let previous = current.last, let first = current.first {
                let pause = word.startTime - previous.endTime
                let sentenceEnded = previous.word.last.map { ".?!".contains($0) } ?? false
                if pause >= 1.0 || (sentenceEnded && previous.endTime - first.startTime >= 2.0)
                    || word.endTime - first.startTime > 30 {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        return segments
    }
}

public enum PianissimoError: LocalizedError {
    case localOnlyMode
    case checksumMismatch(String)
    case incompleteInstall
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .localOnlyMode:
            return "Local-only mode is enabled — model downloads are disabled. Turn it off in Settings to download models."
        case .checksumMismatch(let file):
            return "Downloaded file failed verification (\(file)). Try again."
        case .incompleteInstall:
            return "The Pianissimo model could not be installed completely. Try again."
        case .httpError(let code):
            return "Model download failed (HTTP \(code))."
        }
    }
}

/// Single-file download with byte-level progress and throughput.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Double?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let startedAt = Date()
    private let lock = NSLock()

    private init(onProgress: @escaping @Sendable (Int64, Double?) -> Void) {
        self.onProgress = onProgress
    }

    static func download(
        from url: URL,
        onProgress: @escaping @Sendable (Int64, Double?) -> Void
    ) async throws -> URL {
        let delegate = FileDownloader(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func resume(with result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let elapsed = Date().timeIntervalSince(startedAt)
        onProgress(totalBytesWritten, elapsed > 0.5 ? Double(totalBytesWritten) / elapsed : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            resume(with: .failure(PianissimoError.httpError(http.statusCode)))
            return
        }
        // The system deletes `location` when this returns — move it first
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("pianissimo-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            resume(with: .success(kept))
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resume(with: .failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
    }
}
