import Foundation
import AVFoundation

final class BergetTranscriptionService: Sendable {
    private let apiKey: String
    private let baseURL = "https://api.berget.ai/v1"
    private let model = "KBLab/kb-whisper-large"
    
    init(apiKey: String) {
        self.apiKey = apiKey
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
        
        // Create multipart form data
        // Berget API only accepts: file (required) and model (optional)
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
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorData["error"] as? String {
                throw CloudTranscriptionError.apiError(errorMessage)
            }
            throw CloudTranscriptionError.httpError(httpResponse.statusCode)
        }
        
        // Parse response — Berget returns {"text": "...", "usage": {...}}
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        if let text = json?["text"] as? String {
            return TranscriptionResult(
                text: text,
                segments: [],
                language: language ?? "unknown",
                duration: getAudioDuration(url: audioURL) ?? 0,
                timestamp: Date(),
                modelUsed: model
            )
        } else {
            throw CloudTranscriptionError.invalidResponse
        }
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