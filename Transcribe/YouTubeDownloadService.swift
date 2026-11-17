import Foundation
import TranscribeKit
import SwiftUI
import YouTubeKit
import AVFoundation
@MainActor
class YouTubeDownloadService: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    @Published var videoTitle: String?
    @Published var videoThumbnailURL: URL?
    @Published var videoDuration: String?
    @Published var downloadedFileURL: URL?
    
    /// Identifies the download in flight, so a progress report that arrives
    /// late from a cancelled download can't move the next one's bar.
    private var downloadGeneration = 0

    /// YouTube import only works over the network. Local-only mode hides it
    /// in the UI, but the promise is enforced here, in front of every
    /// request, so no other route into this service can reach the network.
    private nonisolated static func requireNetworkAllowed() throws {
        if UserDefaults.standard.bool(forKey: "localOnlyMode") {
            throw YouTubeError.localOnlyMode
        }
    }

    func fetchVideoInfo(from urlString: String) async throws -> (title: String, thumbnailURL: URL?, duration: String?) {
        try Self.requireNetworkAllowed()
        guard let videoID = extractVideoID(from: urlString) else {
            throw YouTubeError.invalidURL
        }
        
        // The medium thumbnail exists for every video and is 16:9; the
        // maximum-resolution one is missing for many.
        let thumbnailURL = URL(string: "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg")

        // Try to fetch title from YouTube page
        var title = localized("youtube_untitled_video")
        if let pageTitle = await fetchVideoTitleFromPage(videoID: videoID) {
            title = pageTitle
        }
        // The title fetch swallows its errors, a cancellation included
        try Task.checkCancellation()
        
        // Duration is not directly available, return nil for now
        let duration: String? = nil
        
        return (
            title: title,
            thumbnailURL: thumbnailURL,
            duration: duration
        )
    }
    
    private func fetchVideoTitleFromPage(videoID: String) async -> String? {
        guard (try? Self.requireNetworkAllowed()) != nil else { return nil }
        let urlString = "https://www.youtube.com/watch?v=\(videoID)"
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            
            // Try to extract title from meta tags
            if let titleRange = html.range(of: "<title>") {
                let afterTitle = html[titleRange.upperBound...]
                if let endRange = afterTitle.range(of: "</title>") {
                    var title = String(afterTitle[..<endRange.lowerBound])
                    // Remove " - YouTube" suffix
                    title = title.replacingOccurrences(of: " - YouTube", with: "")
                    return title
                }
            }
            
            // Alternative: Try meta property
            if let metaRange = html.range(of: "property=\"og:title\" content=\"") {
                let afterMeta = html[metaRange.upperBound...]
                if let endRange = afterMeta.range(of: "\"") {
                    return String(afterMeta[..<endRange.lowerBound])
                }
            }
        } catch {
            // The title is optional: the caller falls back to a generic one
        }
        
        return nil
    }
    
    private func formatDuration(seconds: Int?) -> String? {
        guard let seconds = seconds else { return nil }
        
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
    
    /// Downloads the audio of a video and returns the local file. On any
    /// failure or cancellation nothing is left on disk.
    func downloadVideoForTranscription(from urlString: String) async throws -> URL {
        try Self.requireNetworkAllowed()
        guard let videoID = extractVideoID(from: urlString) else {
            throw YouTubeError.invalidURL
        }
        
        downloadGeneration += 1
        isDownloading = true
        downloadProgress = 0.0
        errorMessage = nil
        defer { isDownloading = false }
        
        // Fetch streams in a nonisolated context to avoid Sendable issues with YouTube type
        let streams: [YouTubeKit.Stream]
        do {
            streams = try await Self.fetchStreams(videoID: videoID)
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError {
            // Network errors should surface with their real description
            throw error
        } catch let error as YouTubeError {
            throw error
        } catch let error as YouTubeKitError {
            // Most of these describe the video (private, age-restricted, …),
            // not a change on YouTube's side
            throw YouTubeError(error)
        } catch {
            // Anything else (signature solving, response decoding) means the
            // page no longer looks the way YouTubeKit expects
            throw YouTubeError.extractionFailed
        }

        // Prioritize audio-only streams for fastest download and transcription.
        // AVFoundation cannot decode WebM/Opus, so only pick formats it can play.
        let targetStream: YouTubeKit.Stream

        let audioStreams = streams.filterAudioOnly()
        if let m4aStream = audioStreams.first(where: { $0.fileExtension == .m4a }) {
            // Prefer M4A format for best compatibility
            targetStream = m4aStream
        } else if let compatibleAudio = audioStreams.first(where: { $0.fileExtension != .webm }) {
            targetStream = compatibleAudio
        } else if let lowestMP4Video = streams.filter({ $0.fileExtension == .mp4 }).lowestResolutionStream() {
            // No compatible audio-only stream — use the lowest resolution MP4 video
            // and extract its audio after download
            targetStream = lowestMP4Video
        } else {
            // Only WebM streams available — fail fast before downloading anything
            throw YouTubeError.noSuitableStream
        }

        return try await downloadStream(targetStream, videoID: videoID)
    }
    
    /// Fetch YouTube streams in a nonisolated context to avoid sending non-Sendable YouTube type across actor boundaries
    private nonisolated static func fetchStreams(videoID: String) async throws -> [YouTubeKit.Stream] {
        try requireNetworkAllowed()
        let video = YouTube(videoID: videoID, methods: [.local])
        return try await video.streams
    }
    
    private func downloadStream(_ stream: YouTubeKit.Stream, videoID: String) async throws -> URL {
        try Self.requireNetworkAllowed()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe")
            .appendingPathComponent("YouTube")
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw YouTubeError.writeFailed(error.localizedDescription)
        }
        
        let fileExtension = stream.fileExtension.rawValue
        let fileName = "youtube_\(videoID).\(fileExtension)"
        let localURL = tempDir.appendingPathComponent(fileName)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: localURL)
        
        // Use simple URLSession without custom headers that might break YouTube
        let session = URLSession.shared

        // First, get the file size with a HEAD request
        var headRequest = URLRequest(url: stream.url)
        headRequest.httpMethod = "HEAD"

        let (_, headResponse) = try await session.data(for: headRequest)
        let headStatusCode = (headResponse as? HTTPURLResponse)?.statusCode ?? 0
        // Only trust the reported size if the HEAD request actually succeeded
        let totalSize = (200...299).contains(headStatusCode) ? headResponse.expectedContentLength : -1

        // The transfer runs off the main actor and reports back here
        let generation = downloadGeneration
        let reportProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.downloadGeneration == generation, self.isDownloading else { return }
                // Reports are unordered once they hop actors: never move backwards
                self.downloadProgress = max(self.downloadProgress, min(fraction, 1.0))
            }
        }

        do {
            if totalSize > 0 {
                try await Self.downloadInChunks(from: stream.url, to: localURL, totalSize: totalSize, session: session, onProgress: reportProgress)
            } else {
                // Fallback: stream to disk when the total size is unknown
                try await StreamingFileDownload.run(from: stream.url, to: localURL, onProgress: reportProgress)
            }
        } catch {
            // Don't leave a partial file behind on failure or cancellation
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }

        downloadedFileURL = localURL
        downloadProgress = 1.0

        // Convert to audio format if it's a video file
        if fileExtension != "m4a" && fileExtension != "mp3" {
            do {
                let audioURL = try await Self.extractAudio(from: localURL, videoID: videoID)
                downloadedFileURL = audioURL
                return audioURL
            } catch {
                cleanup()
                throw error
            }
        }

        return localURL
    }

    /// Opens a new, empty file for writing.
    fileprivate nonisolated static func openForWriting(_ url: URL) throws -> FileHandle {
        do {
            // Unlike FileManager.createFile, this says why it failed
            try Data().write(to: url)
            return try FileHandle(forWritingTo: url)
        } catch {
            throw YouTubeError.writeFailed(error.localizedDescription)
        }
    }

    /// Runs off the main actor: every chunk is written to disk as it arrives.
    private nonisolated static func downloadInChunks(
        from url: URL,
        to localURL: URL,
        totalSize: Int64,
        session: URLSession,
        onProgress: @Sendable (Double) -> Void
    ) async throws {
        // Download in 2MB chunks to avoid throttling, writing each chunk to disk incrementally
        let chunkSize: Int64 = 2 * 1024 * 1024  // 2MB chunks as recommended in GitHub issue
        var currentOffset: Int64 = 0

        let fileHandle = try openForWriting(localURL)

        defer {
            try? fileHandle.close()
        }

        while currentOffset < totalSize {
            try Task.checkCancellation()
            // Local-only mode may be switched on while a download is running
            try requireNetworkAllowed()

            let endOffset = min(currentOffset + chunkSize - 1, totalSize - 1)

            // Create range request
            var request = URLRequest(url: url)
            request.setValue("bytes=\(currentOffset)-\(endOffset)", forHTTPHeaderField: "Range")

            let (chunkData, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw YouTubeError.downloadFailed
            }

            switch httpResponse.statusCode {
            case 206:
                // Partial content — verify the server sent exactly the requested range
                guard Int64(chunkData.count) == endOffset - currentOffset + 1 else {
                    throw YouTubeError.downloadFailed
                }
                currentOffset = endOffset + 1
            case 200 where currentOffset == 0:
                // Server ignored the Range header and sent the whole file
                guard Int64(chunkData.count) == totalSize else {
                    throw YouTubeError.downloadFailed
                }
                currentOffset = totalSize
            default:
                throw YouTubeError.downloadFailed
            }

            // The throwing API: `write(_:)` raises an Objective-C exception
            // (a crash) when the disk is full.
            do {
                try fileHandle.write(contentsOf: chunkData)
            } catch {
                throw YouTubeError.writeFailed(error.localizedDescription)
            }

            onProgress(Double(currentOffset) / Double(totalSize))
        }
    }

    /// Exports the audio track of a downloaded video to .m4a and removes the
    /// video. When there is nothing to export, or the export fails, the video
    /// itself is returned: the transcription pipeline extracts audio from
    /// video containers on its own.
    private nonisolated static func extractAudio(from videoURL: URL, videoID: String) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        
        // Check if asset has audio track
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty,
              let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return videoURL
        }
        
        let outputURL = videoURL.deletingLastPathComponent().appendingPathComponent("youtube_\(videoID).m4a")
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        do {
            try await exportSession.export(to: outputURL, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            // A cancelled export must stop the flow, not pass the video on
            try Task.checkCancellation()
            return videoURL
        }
        
        // Clean up original video file
        try? FileManager.default.removeItem(at: videoURL)
        return outputURL
    }
    
    func extractVideoID(from urlString: String) -> String? {
        // Accept scheme-less URLs (e.g. "youtube.com/watch?v=...")
        var normalizedString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedString.contains("://") {
            normalizedString = "https://" + normalizedString
        }

        guard let url = URL(string: normalizedString) else { return nil }

        // Handle youtu.be format
        if url.host == "youtu.be" || url.host == "www.youtu.be" {
            return url.pathComponents.last
        }

        // Handle youtube.com format
        if url.host == "youtube.com" || url.host == "www.youtube.com" || url.host == "m.youtube.com" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value {
                return videoID
            }

            // Handle embed, Shorts and live formats (/embed/<id>, /shorts/<id>, /live/<id>)
            let pathComponents = url.pathComponents
            if let markerIndex = pathComponents.firstIndex(where: { ["embed", "shorts", "live"].contains($0) }),
               markerIndex + 1 < pathComponents.count {
                return pathComponents[markerIndex + 1]
            }
        }

        return nil
    }
    
    /// Removes a downloaded file that will not be transcribed: a later step
    /// failed, or the user cancelled before it was handed on. Must not be
    /// called after a hand-off — the transcription screen reads the file,
    /// and the app empties its temp folder when it quits.
    func cleanup() {
        guard let fileURL = downloadedFileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        downloadedFileURL = nil
    }
}

/// Streams a response body of unknown length to a file as it arrives.
///
/// URLSession delivers the body in chunks on its own serial delegate queue,
/// so nothing is buffered whole in memory and none of the work runs on the
/// main actor.
private final class StreamingFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Touched only on the session's serial delegate queue
    private let fileHandle: FileHandle
    private let onProgress: @Sendable (Double) -> Void
    private var failure: YouTubeError?
    private var expectedLength: Int64 = -1
    private var bytesWritten: Int64 = 0
    private var lastReportedPercent = -1

    // The caller installs its continuation while the delegate queue may
    // already be delivering the result (a download cancelled at once)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    private init(fileHandle: FileHandle, onProgress: @escaping @Sendable (Double) -> Void) {
        self.fileHandle = fileHandle
        self.onProgress = onProgress
    }

    static func run(from url: URL, to localURL: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let fileHandle = try YouTubeDownloadService.openForWriting(localURL)
        let download = StreamingFileDownload(fileHandle: fileHandle, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        // A session keeps its delegate alive until it is invalidated
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                download.install(continuation)
                task.resume()
            }
        } onCancel: {
            // Ends in didCompleteWithError, which reports the cancellation
            task.cancel()
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            failure = .downloadFailed
            completionHandler(.cancel)
            return
        }
        expectedLength = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            // Typically a full disk: stop the transfer instead of crashing
            failure = .writeFailed(error.localizedDescription)
            dataTask.cancel()
            return
        }
        bytesWritten += Int64(data.count)

        // Periodic progress when the response reports a length
        guard expectedLength > 0 else { return }
        let fraction = Double(bytesWritten) / Double(expectedLength)
        let percent = Int(fraction * 100)
        if percent != lastReportedPercent {
            lastReportedPercent = percent
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? fileHandle.close()
        if let failure {
            finish(.failure(failure))
        } else if let error {
            let wasCancelled = (error as? URLError)?.code == .cancelled
            finish(.failure(wasCancelled ? CancellationError() : error))
        } else {
            finish(.success(()))
        }
    }
}

enum YouTubeError: LocalizedError {
    case invalidURL
    case localOnlyMode
    case noSuitableStream
    case downloadFailed
    /// The file could not be created or written; carries the system's reason.
    case writeFailed(String)
    case videoPrivate
    case ageRestricted
    case membersOnly
    case liveStream
    case recordingUnavailable
    case regionBlocked
    case videoUnavailable
    case noResponse
    /// YouTubeKit could not make sense of what YouTube returned.
    case extractionFailed

    /// Translates YouTubeKit's reasons. Only its parsing failures suggest
    /// that YouTube changed; the others say something about the video.
    init(_ error: YouTubeKitError) {
        switch error {
        case .videoPrivate: self = .videoPrivate
        case .videoAgeRestricted: self = .ageRestricted
        case .membersOnly: self = .membersOnly
        case .liveStreamError: self = .liveStream
        case .recordingUnavailable: self = .recordingUnavailable
        case .videoRegionBlocked: self = .regionBlocked
        case .videoUnavailable: self = .videoUnavailable
        case .maxRetriesExceeded: self = .noResponse
        case .htmlParseError, .extractError, .regexMatchError: self = .extractionFailed
        @unknown default: self = .extractionFailed
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return localized("youtube_error_invalid_url")
        case .localOnlyMode:
            return localized("youtube_local_only")
        case .noSuitableStream:
            return localized("youtube_error_no_stream")
        case .downloadFailed:
            return localized("youtube_error_download_failed")
        case .writeFailed(let reason):
            return String(format: localized("youtube_error_write_failed"), reason)
        case .videoPrivate:
            return localized("youtube_error_private")
        case .ageRestricted:
            return localized("youtube_error_age_restricted")
        case .membersOnly:
            return localized("youtube_error_members_only")
        case .liveStream:
            return localized("youtube_error_live")
        case .recordingUnavailable:
            return localized("youtube_error_recording_unavailable")
        case .regionBlocked:
            return localized("youtube_error_region_blocked")
        case .videoUnavailable:
            return localized("youtube_error_unavailable")
        case .noResponse:
            return localized("youtube_error_no_response")
        case .extractionFailed:
            return localized("youtube_error_extraction")
        }
    }
}
