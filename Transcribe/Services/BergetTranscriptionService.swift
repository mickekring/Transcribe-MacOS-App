import Foundation
import AVFoundation

final class BergetTranscriptionService: Sendable {
    private let apiKey: String
    private let baseURL = "https://api.berget.ai/v1"
    private let model: String

    init(apiKey: String, model: String = "KBLab/kb-whisper-large") {
        self.apiKey = apiKey
        self.model = model
    }
    
    func transcribe(
        audioURL: URL,
        language: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil,
        completion: @Sendable @escaping (Result<TranscriptionResult, Error>) -> Void
    ) {
        Task {
            do {
                // First, check if streaming is supported
                let supportsStreaming = await checkStreamingSupport()
                
                if supportsStreaming {
                    // Try streaming transcription
                    try await transcribeWithStreaming(
                        audioURL: audioURL,
                        language: language,
                        onProgress: onProgress,
                        completion: completion
                    )
                } else {
                    // Fall back to regular transcription
                    let result = try await transcribeWithoutStreaming(
                        audioURL: audioURL,
                        language: language
                    )
                    
                    await MainActor.run {
                        completion(.success(result))
                    }
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }
    
    private func transcribeWithoutStreaming(
        audioURL: URL,
        language: String? = nil
    ) async throws -> TranscriptionResult {
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
        request.timeoutInterval = 300 // 5 minutes for large files
        
        // Perform request
        let (data, response) = try await URLSession.shared.data(for: request)
        
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
        
        // Parse the verbose response:
        // {"text": "...", "language": "sv", "segments": {"segments": [
        //   {"start": 0.0, "end": 2.5, "speaker": "SPEAKER_00", "text": "..."},
        // ...], "word_segments": [...]}}
        // The segment list is nested one level deeper than the docs show;
        // tolerate a flat list too.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let text = json?["text"] as? String else {
            throw CloudTranscriptionError.invalidResponse
        }

        var rawSegments: [[String: Any]] = []
        if let container = json?["segments"] as? [String: Any],
           let inner = container["segments"] as? [[String: Any]] {
            rawSegments = inner
        } else if let flat = json?["segments"] as? [[String: Any]] {
            rawSegments = flat
        }

        let segments: [TranscriptionSegment] = rawSegments.enumerated().compactMap { index, raw in
            guard let start = raw["start"] as? Double,
                  let end = raw["end"] as? Double,
                  let segmentText = raw["text"] as? String else { return nil }
            // With align=true each segment carries word timings; with
            // diarize=true each word may carry its own speaker label
            let words: [TranscriptionWord]? = (raw["words"] as? [[String: Any]])?.compactMap { rawWord in
                guard let text = rawWord["word"] as? String,
                      let wordStart = rawWord["start"] as? Double,
                      let wordEnd = rawWord["end"] as? Double else { return nil }
                return TranscriptionWord(
                    word: text,
                    start: wordStart,
                    end: wordEnd,
                    speaker: rawWord["speaker"] as? String
                )
            }
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

        return TranscriptionResult(
            text: text,
            segments: segments,
            language: (json?["language"] as? String) ?? appliedLanguage ?? "unknown",
            duration: getAudioDuration(url: audioURL) ?? 0,
            timestamp: Date(),
            modelUsed: model
        )
    }
    
    private func transcribeWithStreaming(
        audioURL: URL,
        language: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil,
        completion: @Sendable @escaping (Result<TranscriptionResult, Error>) -> Void
    ) async throws {
        // For now, we'll implement this as a TODO since Berget might not support streaming yet
        // We'll fall back to regular transcription
        let result = try await transcribeWithoutStreaming(audioURL: audioURL, language: language)
        await MainActor.run {
            completion(.success(result))
        }
    }
    
    private func checkStreamingSupport() async -> Bool {
        // Check if Berget supports streaming
        // For now, return false as they likely don't support it yet
        return false
    }
    
    private func getAudioDuration(url: URL) -> Double? {
        let asset = AVAsset(url: url)
        let duration = asset.duration
        let durationInSeconds = CMTimeGetSeconds(duration)
        return durationInSeconds.isFinite ? durationInSeconds : nil
    }
}

enum CloudTranscriptionError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case fileNotFound
    
    var errorDescription: String? {
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