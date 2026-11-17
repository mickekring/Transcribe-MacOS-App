import Foundation
import AVFoundation
import os

public final class BergetTranscriptionService: Sendable {
    private let apiKey: String
    private let baseURL = "https://api.berget.ai/v1"
    private let model: String

    /// The longest Berget works on one request — the cap AudioPreprocessor
    /// sizes its uploads for.
    private static let maxProcessingTime: TimeInterval = 30 * 60

    /// Requests started through the callback API whose completion handler
    /// has not been called yet.
    private struct Requests: Sendable {
        var active: Set<UUID> = []
        var tasks: [UUID: Task<Void, Never>] = [:]
    }
    private let requests = OSAllocatedUnfairLock(initialState: Requests())

    public init(apiKey: String, model: String = "KBLab/kb-whisper-large") {
        self.apiKey = apiKey
        self.model = model
    }

    /// Transcribes a file and reports the outcome to `completion` on the main
    /// actor, unless `cancel()` is called first.
    ///
    /// `onProgress` is never called: Berget returns a transcription in one
    /// response, there is no partial text to report.
    public func transcribe(
        audioURL: URL,
        language: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil,
        completion: @Sendable @escaping (Result<TranscriptionResult, Error>) -> Void
    ) {
        let id = UUID()
        requests.withLock { _ = $0.active.insert(id) }

        let task = Task {
            let result: Result<TranscriptionResult, Error>
            do {
                result = .success(try await self.transcribe(audioURL: audioURL, language: language))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                // cancel() takes the request off the list; whatever arrives
                // after that is no longer wanted.
                let isStillWanted = self.requests.withLock { requests in
                    requests.tasks[id] = nil
                    return requests.active.remove(id) != nil
                }
                if isStillWanted {
                    completion(result)
                }
            }
        }

        // The request may have been cancelled, or even have finished, before
        // its task could be put on the list.
        let isStillWanted = requests.withLock { requests in
            guard requests.active.contains(id) else { return false }
            requests.tasks[id] = task
            return true
        }
        if !isStillWanted {
            task.cancel()
        }
    }

    /// Stops every request started through the callback API.
    ///
    /// Their completion handlers are not called at all after this — neither
    /// with a result that was about to arrive nor with an error. Handlers
    /// run on the main actor, so a `cancel()` made there is exact; from
    /// another thread, a handler that had already begun can still finish.
    ///
    /// Code that waits for a completion handler (in a continuation, say)
    /// must therefore not rely on it after cancelling; the async
    /// `transcribe(audioURL:language:)` is the variant to await.
    public func cancel() {
        let tasks = requests.withLock { requests in
            let tasks = Array(requests.tasks.values)
            requests = Requests()
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
    }

    /// Transcribes a file. Cancelling the calling task cancels the request
    /// itself and throws `CancellationError`.
    public func transcribe(
        audioURL: URL,
        language: String? = nil
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let boundary = UUID().uuidString

        // Only send a language when one was explicitly selected ("auto"/nil
        // means server-side auto-detect, and the result stays "unknown").
        let appliedLanguage: String? = {
            guard let language, !language.isEmpty, language != "auto" else { return nil }
            return language
        }()

        // Create multipart form data (OpenAI-compatible: file, model, language)
        var body = Data()

        // Map file extension to proper MIME type
        let mimeType: String
        switch audioURL.pathExtension.lowercased() {
        case "mp3", "mpga":  mimeType = "audio/mpeg"
        case "mp4", "m4a":   mimeType = "audio/mp4"
        case "wav":          mimeType = "audio/wav"
        case "webm":         mimeType = "audio/webm"
        case "ogg":          mimeType = "audio/ogg"
        case "flac":         mimeType = "audio/flac"
        default:             mimeType = "application/octet-stream"
        }

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audioURL))
        body.append("\r\n".data(using: .utf8)!)

        // Add model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Add language (ISO-639-1) when explicitly selected
        if let appliedLanguage {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(appliedLanguage)\r\n".data(using: .utf8)!)
        }

        // Segments with timing + speaker labels (WhisperX features).
        // Diarization has minimal processing-time impact per Berget's docs.
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"diarize\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)
        // Word-level timestamps: powers word-precise speaker turns
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"align\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        // Create request
        var request = URLRequest(url: URL(string: "\(baseURL)/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // This is an idle timeout, and the request is idle for as long as the
        // server is transcribing: not a byte comes back between the end of
        // the upload and the finished result. It has to outlast the longest
        // job the service accepts, with some room for queueing.
        request.timeoutInterval = Self.maxProcessingTime + 120

        // Perform request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // URLSession reports a cancelled task as URLError(.cancelled)
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // OpenAI-compatible APIs return {"error": {"message": "..."}}
                if let errorDict = errorData["error"] as? [String: Any],
                   let errorMessage = errorDict["message"] as? String {
                    throw CloudTranscriptionError.apiError(errorMessage)
                }
                // Fallback: plain {"error": "string"} shape
                if let errorMessage = errorData["error"] as? String {
                    throw CloudTranscriptionError.apiError(errorMessage)
                }
            }
            throw CloudTranscriptionError.httpError(httpResponse.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let json, let text = json["text"] as? String else {
            throw CloudTranscriptionError.invalidResponse
        }

        return TranscriptionResult(
            text: text,
            segments: Self.segments(fromResponse: json),
            language: (json["language"] as? String) ?? appliedLanguage ?? "unknown",
            duration: await audioDuration(of: audioURL) ?? 0,
            timestamp: Date(),
            modelUsed: model
        )
    }

    /// Reads the segments of a verbose response:
    /// {"text": "...", "language": "sv", "segments": {"segments": [
    ///   {"start": 0.0, "end": 2.5, "speaker": "SPEAKER_00", "text": "...", "words": [...]},
    /// ...], "word_segments": [...]}}
    /// The segment list is nested one level deeper than the docs show;
    /// a flat list is tolerated too.
    static func segments(fromResponse json: [String: Any]) -> [TranscriptionSegment] {
        var rawSegments: [[String: Any]] = []
        if let container = json["segments"] as? [String: Any],
           let inner = container["segments"] as? [[String: Any]] {
            rawSegments = inner
        } else if let flat = json["segments"] as? [[String: Any]] {
            rawSegments = flat
        }

        return rawSegments.enumerated().compactMap { index, raw in
            guard let start = raw["start"] as? Double,
                  let end = raw["end"] as? Double,
                  let segmentText = raw["text"] as? String else { return nil }
            // With align=true each segment carries word timings; with
            // diarize=true each word may carry its own speaker label
            let words = (raw["words"] as? [[String: Any]]).map { Self.words(from: $0, segmentStart: start) }
            return TranscriptionSegment(
                id: index,
                start: start,
                end: end,
                text: segmentText.trimmingCharacters(in: .whitespaces),
                confidence: nil,
                speaker: raw["speaker"] as? String,
                words: (words?.isEmpty == false) ? words : nil
            )
        }
    }

    /// Reads the words of one segment, keeping those that have no timing.
    ///
    /// The aligner gives no `start`/`end` to a word it cannot place in the
    /// audio — numerals and symbols, typically. Such a word is still part of
    /// what was said; it is placed at the moment the word before it ends (or,
    /// when it leads the segment, where the next timed word starts), which
    /// keeps it in order and with the speaker of its neighbour.
    static func words(from rawWords: [[String: Any]], segmentStart: Double) -> [TranscriptionWord] {
        let raw = rawWords.compactMap { raw -> (text: String, start: Double?, end: Double?, speaker: String?)? in
            guard let text = raw["word"] as? String else { return nil }
            return (text, raw["start"] as? Double, raw["end"] as? Double, raw["speaker"] as? String)
        }

        var words: [TranscriptionWord] = []
        for (index, word) in raw.enumerated() {
            let start: Double
            let end: Double
            if let known = word.start ?? word.end {
                start = word.start ?? known
                end = word.end ?? known
            } else {
                let neighbour = words.last?.end
                    ?? raw[index...].lazy.compactMap { $0.start ?? $0.end }.first
                    ?? segmentStart
                start = neighbour
                end = neighbour
            }
            words.append(TranscriptionWord(word: word.text, start: start, end: end, speaker: word.speaker))
        }
        return words
    }

    private func audioDuration(of url: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }
}

public enum CloudTranscriptionError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case fileNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .apiError(let message):
            return "API error: \(message)"
        case .fileNotFound:
            return "Audio file not found"
        }
    }
}
