import Foundation

/// Unified LLM service supporting OpenAI-compatible chat completion APIs (Berget, Ollama).
/// Streams responses token-by-token via an AsyncThrowingStream.
final class LLMService: Sendable {
    
    enum Provider: String, Sendable {
        case berget
        case ollama
    }
    
    enum LLMError: LocalizedError {
        case noAPIKey
        case invalidURL
        case httpError(Int, String?)
        case noContent
        case streamingFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "API key is required for this provider"
            case .invalidURL:
                return "Invalid API URL"
            case .httpError(let code, let message):
                return "HTTP \(code): \(message ?? "Unknown error")"
            case .noContent:
                return "No content in response"
            case .streamingFailed(let reason):
                return "Streaming failed: \(reason)"
            }
        }
    }
    
    /// Sends a chat completion request and streams the response text.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system prompt (selected prompt + additional info)
    ///   - userMessage: The transcription text
    ///   - provider: Which LLM provider to use
    ///   - model: The model ID (e.g. "meta-llama/Llama-3.3-70B-Instruct")
    ///   - apiKey: API key (required for Berget, ignored for Ollama)
    ///   - ollamaHost: Ollama base URL (default localhost:11434)
    /// - Returns: An AsyncThrowingStream of String tokens
    func streamCompletion(
        systemPrompt: String,
        userMessage: String,
        provider: Provider,
        model: String,
        apiKey: String = "",
        ollamaHost: String = "http://127.0.0.1:11434"
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let baseURL: String
                    switch provider {
                    case .berget:
                        guard !apiKey.isEmpty else {
                            continuation.finish(throwing: LLMError.noAPIKey)
                            return
                        }
                        baseURL = "https://api.berget.ai/v1"
                    case .ollama:
                        baseURL = ollamaHost + "/v1"
                    }
                    
                    guard let url = URL(string: "\(baseURL)/chat/completions") else {
                        continuation.finish(throwing: LLMError.invalidURL)
                        return
                    }
                    
                    // Build request body
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": systemPrompt],
                            ["role": "user", "content": userMessage]
                        ]
                    ]
                    
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if provider == .berget {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    request.timeoutInterval = 300
                    
                    // Use URLSession bytes for streaming
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.httpError(0, "Invalid response"))
                        return
                    }
                    
                    guard (200...299).contains(httpResponse.statusCode) else {
                        // Try to read error body
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        continuation.finish(throwing: LLMError.httpError(httpResponse.statusCode, errorBody))
                        return
                    }
                    
                    // Parse SSE stream
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        
                        // SSE format: "data: {...}"
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6))
                        
                        // Check for stream end
                        if jsonString == "[DONE]" {
                            break
                        }
                        
                        // Parse the JSON chunk
                        guard let data = jsonString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }
                        
                        continuation.yield(content)
                    }
                    
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    }
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
