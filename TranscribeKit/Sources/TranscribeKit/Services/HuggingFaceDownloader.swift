import Foundation
import CryptoKit
import os

/// Errors shared by every local-model download path.
public enum ModelDownloadError: LocalizedError {
    case localOnlyMode
    case stalledRepeatedly
    case listingFailed(String)
    case httpStatus(Int, String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .localOnlyMode:
            return "Local-only mode is enabled — model downloads are disabled. Turn it off in Settings to download models."
        case .stalledRepeatedly:
            return "The download kept stalling. Check your internet connection and try again."
        case .listingFailed(let detail):
            return "Could not read the model's file list (\(detail))."
        case .httpStatus(let status, let file):
            return "The server answered \(status) for \(file)."
        case .verificationFailed(let file):
            return "\(file) did not match its expected size or checksum after download."
        }
    }
}

/// Fetches a fixed set of files from a Hugging Face model repository at a
/// pinned commit.
///
/// Used for models that don't go through WhisperKit's own downloader. The
/// revision is pinned so a third-party repository cannot swap a model
/// underneath the app, and every file is checked against the size (and, for
/// LFS files, the SHA-256) that the repository lists for that commit before
/// the folder is accepted. Interrupted transfers resume from the bytes
/// already on disk.
public enum HuggingFaceDownloader {

    public struct Snapshot: Sendable {
        public let repo: String
        public let revision: String
        /// Top-level files or folders to fetch. `nil` fetches the whole repo.
        public let entries: [String]?

        public init(repo: String, revision: String, entries: [String]?) {
            self.repo = repo
            self.revision = revision
            self.entries = entries
        }
    }

    public struct Progress: Sendable {
        public let bytesDone: Int64
        public let bytesTotal: Int64
        public let bytesPerSecond: Double

        public var fraction: Double {
            bytesTotal > 0 ? min(Double(bytesDone) / Double(bytesTotal), 1) : 0
        }
    }

    struct RemoteFile: Sendable {
        let path: String
        let size: Int64
        let sha256: String?
    }

    private static let logger = Logger(subsystem: "com.mickekring.transcribe", category: "ModelDownload")

    /// Attempts per file. A stalled attempt costs ~30 s and resumes from the
    /// partial file, so a generous budget rides out a bad CDN patch.
    private static let maxAttemptsPerFile = 20

    /// Downloads `snapshot` into `destination`, replacing whatever is there.
    ///
    /// Files are staged next to the destination and moved into place only
    /// once all of them verify, so `destination` either holds a complete model
    /// or does not exist.
    public static func download(
        _ snapshot: Snapshot,
        to destination: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        guard !UserDefaults.standard.bool(forKey: "localOnlyMode") else {
            throw ModelDownloadError.localOnlyMode
        }

        let files = try await listFiles(snapshot)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let staging = stagingDirectory(for: destination)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let meter = ProgressMeter(total: total, report: progress)

        for file in files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            if fileSize(target) == file.size {
                if try await verify(target, against: file) {
                    meter.skip(file.size)
                    continue
                }
                // Right size, wrong content: resuming can't repair it
                try? fm.removeItem(at: target)
            }
            try await fetch(file, from: snapshot, to: target, meter: meter)
            guard try await verify(target, against: file) else {
                try? fm.removeItem(at: target)
                throw ModelDownloadError.verificationFailed(file.path)
            }
        }

        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: destination)
        meter.finish()
    }

    /// Where a download accumulates before it is verified and moved into place.
    public static func stagingDirectory(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).download")
    }

    // MARK: - Listing

    static func listFiles(_ snapshot: Snapshot) async throws -> [RemoteFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(snapshot.repo)/tree/\(snapshot.revision)?recursive=true") else {
            throw ModelDownloadError.listingFailed("bad repository name")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ModelDownloadError.listingFailed("HTTP \(status)")
        }
        return try parseListing(data, entries: snapshot.entries)
    }

    /// Parses the repository tree response. The listing comes from the
    /// network, so every path is validated before it is ever joined onto a
    /// local directory.
    static func parseListing(_ data: Data, entries: [String]?) throws -> [RemoteFile] {
        struct Entry: Decodable {
            struct LFS: Decodable { let oid: String? }
            let type: String
            let path: String
            let size: Int64?
            let lfs: LFS?
        }
        let decoded: [Entry]
        do {
            decoded = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw ModelDownloadError.listingFailed("unexpected response")
        }

        let wanted = entries.map(Set.init)
        var files: [RemoteFile] = []
        for entry in decoded where entry.type == "file" {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard isSafeRelativePath(components) else {
                throw ModelDownloadError.listingFailed("unsafe path in listing")
            }
            if let wanted, !wanted.contains(components[0]) { continue }
            guard let size = entry.size, size >= 0 else {
                throw ModelDownloadError.listingFailed("missing size for \(entry.path)")
            }
            files.append(RemoteFile(path: entry.path, size: size, sha256: entry.lfs?.oid))
        }

        // Every requested top-level entry must be present, otherwise a
        // renamed file upstream would yield a "complete" but unusable folder.
        if let wanted {
            let found = Set(files.compactMap { $0.path.split(separator: "/").first.map(String.init) })
            if let missing = wanted.subtracting(found).sorted().first {
                throw ModelDownloadError.listingFailed("\(missing) is missing from the repository")
            }
        }
        guard !files.isEmpty else {
            throw ModelDownloadError.listingFailed("no files")
        }
        return files
    }

    static func isSafeRelativePath(_ components: [String]) -> Bool {
        guard !components.isEmpty else { return false }
        return components.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.contains("\\") && !part.contains("\0")
        }
    }

    // MARK: - Transfer

    private static func fetch(
        _ file: RemoteFile,
        from snapshot: Snapshot,
        to target: URL,
        meter: ProgressMeter
    ) async throws {
        let encodedPath = file.path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(snapshot.repo)/resolve/\(snapshot.revision)/\(encodedPath)") else {
            throw ModelDownloadError.listingFailed("bad file path")
        }

        var attempt = 1
        while true {
            try Task.checkCancellation()
            // A partial file larger than the target can't be a prefix of it
            if fileSize(target) > file.size {
                try? FileManager.default.removeItem(at: target)
            }
            let alreadyOnDisk = max(fileSize(target), 0)
            if alreadyOnDisk == file.size {
                // Complete already (or an empty file, which needs no request)
                if file.size == 0 {
                    FileManager.default.createFile(atPath: target.path, contents: nil)
                }
                meter.skip(file.size)
                return
            }
            meter.beginFile(resumedBytes: alreadyOnDisk)

            do {
                let transfer = RangeTransfer(
                    url: url, fileURL: target, offset: alreadyOnDisk,
                    onBytes: { count in meter.add(Int64(count)) },
                    onRestart: { meter.restartFile() }
                )
                try await transfer.run()
                meter.endFile()
                return
            } catch is CancellationError {
                meter.rollBackFile()
                throw CancellationError()
            } catch let error as ModelDownloadError {
                meter.rollBackFile()
                throw error
            } catch {
                meter.rollBackFile()
                guard attempt < maxAttemptsPerFile, isTransient(error) else {
                    if isTransient(error) { throw ModelDownloadError.stalledRepeatedly }
                    throw error
                }
                attempt += 1
                logger.warning("Transfer of \(file.path, privacy: .public) interrupted (\(error.localizedDescription, privacy: .public)); resuming, attempt \(attempt)")
                try await Task.sleep(for: .seconds(min(Double(attempt), 5)))
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .internationalRoamingOff,
             .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // MARK: - Verification

    private static func verify(_ url: URL, against file: RemoteFile) async throws -> Bool {
        guard fileSize(url) == file.size else { return false }
        guard let expected = file.sha256 else { return true }
        let digest = try await Task.detached(priority: .utility) { try sha256(of: url) }.value
        return digest == expected.lowercased()
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return -1 }
        return size.int64Value
    }
}

// MARK: - Progress accounting

/// Aggregates bytes across files and reports throttled progress with a
/// smoothed transfer speed. Bytes of a failed attempt are rolled back so a
/// retry never counts them twice.
private final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let report: @Sendable (HuggingFaceDownloader.Progress) -> Void
    private var done: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var lastReport = Date.distantPast
    private var speedWindowStart = Date()
    private var speedWindowBytes: Int64 = 0
    private var speed: Double = 0

    init(total: Int64, report: @escaping @Sendable (HuggingFaceDownloader.Progress) -> Void) {
        self.total = total
        self.report = report
    }

    func beginFile(resumedBytes: Int64) {
        lock.lock()
        currentFileBytes = resumedBytes
        done += resumedBytes
        lock.unlock()
    }

    func endFile() {
        lock.lock()
        currentFileBytes = 0
        lock.unlock()
    }

    func rollBackFile() {
        lock.lock()
        done -= currentFileBytes
        currentFileBytes = 0
        lock.unlock()
    }

    /// The server ignored the resume offset and is sending the file from the
    /// start, so the bytes counted for the partial file no longer apply.
    func restartFile() {
        rollBackFile()
    }

    /// Counts a file that was already on disk, without it reading as transfer speed.
    func skip(_ bytes: Int64) {
        lock.lock()
        done += bytes
        let snapshot = HuggingFaceDownloader.Progress(bytesDone: done, bytesTotal: total, bytesPerSecond: speed)
        lock.unlock()
        report(snapshot)
    }

    func add(_ bytes: Int64) {
        lock.lock()
        done += bytes
        currentFileBytes += bytes
        speedWindowBytes += bytes
        let now = Date()
        let windowLength = now.timeIntervalSince(speedWindowStart)
        if windowLength >= 1 {
            let instant = Double(speedWindowBytes) / windowLength
            speed = speed == 0 ? instant : speed * 0.6 + instant * 0.4
            speedWindowStart = now
            speedWindowBytes = 0
        }
        let shouldReport = now.timeIntervalSince(lastReport) >= 0.25
        if shouldReport { lastReport = now }
        let snapshot = HuggingFaceDownloader.Progress(bytesDone: done, bytesTotal: total, bytesPerSecond: speed)
        lock.unlock()
        if shouldReport { report(snapshot) }
    }

    func finish() {
        report(HuggingFaceDownloader.Progress(bytesDone: total, bytesTotal: total, bytesPerSecond: 0))
    }
}

// MARK: - Resumable transfer

/// One HTTP transfer that appends to `fileURL` starting at `offset`.
///
/// The session's request timeout doubles as the stall detector: it fires
/// when no bytes arrive for 30 seconds, and the caller resumes from whatever
/// reached the disk.
private final class RangeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let fileURL: URL
    private let offset: Int64
    private let onBytes: @Sendable (Int) -> Void
    private let onRestart: @Sendable () -> Void

    private let lock = NSLock()
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(
        url: URL,
        fileURL: URL,
        offset: Int64,
        onBytes: @escaping @Sendable (Int) -> Void,
        onRestart: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.fileURL = fileURL
        self.offset = offset
        self.onBytes = onBytes
        self.onRestart = onRestart
    }

    func run() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        // Byte offsets only line up with the file on disk when the body is
        // sent uncompressed.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206:
                // Server honoured the range: append to the partial file
                let handle = try openHandle(truncating: false)
                try handle.seekToEnd()
            case 200:
                // Full body (no partial file, or the range was ignored): start over
                if offset > 0 { onRestart() }
                _ = try openHandle(truncating: true)
            default:
                throw ModelDownloadError.httpStatus(status, fileURL.lastPathComponent)
            }
            completionHandler(.allow)
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handle = self.handle
        lock.unlock()
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            onBytes(data.count)
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        try? handle?.close()
        handle = nil
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        let wasCancelled = cancelled
        lock.unlock()

        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    private func openHandle(truncating: Bool) throws -> FileHandle {
        let fm = FileManager.default
        if truncating || !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        if truncating {
            try handle.truncate(atOffset: 0)
        }
        lock.lock()
        self.handle = handle
        lock.unlock()
        return handle
    }
}
