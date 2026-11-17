import Foundation

/// Unified LLM service supporting OpenAI-compatible chat completion APIs (Berget, Ollama).
/// Streams responses token-by-token via an AsyncThrowingStream.
public final class LLMService: Sendable {

    public init() {}

    public enum Provider: String, Sendable {
        case berget
        case ollama
    }
    
    enum LLMError: LocalizedError {
        case noAPIKey
        case invalidURL
        case httpError(Int, String?)
        case noContent
        case streamingFailed(String)
        /// Local-only mode is on and the request would leave this computer
        case blockedByLocalOnly

        var errorDescription: String? {
            switch self {
            case .blockedByLocalOnly:
                return localized("llm_blocked_local_only")
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
    public func streamCompletion(
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
                    // Local-only mode promises that no text leaves this
                    // computer; the UI already hides Berget, and Ollama may
                    // have been pointed at another machine.
                    let localOnly = UserDefaults.standard.bool(forKey: "localOnlyMode")
                    switch provider {
                    case .berget:
                        guard !localOnly else {
                            continuation.finish(throwing: LLMError.blockedByLocalOnly)
                            return
                        }
                        guard !apiKey.isEmpty else {
                            continuation.finish(throwing: LLMError.noAPIKey)
                            return
                        }
                        baseURL = "https://api.berget.ai/v1"
                    case .ollama:
                        guard !localOnly || Self.isOnThisComputer(ollamaHost) else {
                            continuation.finish(throwing: LLMError.blockedByLocalOnly)
                            return
                        }
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
                        var errorLines: [String] = []
                        for try await line in bytes.lines {
                            errorLines.append(line)
                        }
                        continuation.finish(throwing: LLMError.httpError(httpResponse.statusCode, errorLines.joined(separator: "\n")))
                        return
                    }
                    
                    // Parse SSE stream
                    stream: for try await line in bytes.lines {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }

                        switch Self.streamEvent(fromLine: line) {
                        case .content(let content):
                            continuation.yield(content)
                        case .done:
                            break stream
                        case .failure(let message):
                            // The answer so far is cut short; ending the
                            // stream normally would pass it off as complete.
                            continuation.finish(throwing: LLMError.streamingFailed(message))
                            return
                        case .ignored:
                            continue
                        }
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

    /// What one line of a chat-completion stream means.
    enum StreamEvent: Equatable {
        /// A piece of the answer.
        case content(String)
        /// The end-of-stream marker.
        case done
        /// The server gave up part-way and says why.
        case failure(String)
        /// Nothing to act on: a blank line, a comment, a chunk without text.
        case ignored
    }

    /// Interprets one line of the stream.
    ///
    /// Servers report a failure that happens after the response has started
    /// — the model crashed, a limit was hit — in the stream itself, as an
    /// object with an `error` member where a chunk would be. It comes as an
    /// SSE data line like any chunk, or from some servers as a bare JSON
    /// line.
    static func streamEvent(fromLine line: String) -> StreamEvent {
        let payload: String
        if line.hasPrefix("data: ") {
            // SSE format: "data: {...}"
            payload = String(line.dropFirst(6))
        } else if line.hasPrefix("{") {
            payload = line
        } else {
            return .ignored
        }

        if payload == "[DONE]" {
            return .done
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }

        if let error = json["error"], !(error is NSNull) {
            // OpenAI-compatible: {"error": {"message": "..."}}; Ollama: {"error": "..."}
            if let message = (error as? [String: Any])?["message"] as? String {
                return .failure(message)
            }
            if let message = error as? String {
                return .failure(message)
            }
            return .failure(payload)
        }

        guard line.hasPrefix("data: "),
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return .ignored
        }
        return .content(content)
    }
}

extension LLMService {
    /// Whether an Ollama address points at this computer (loopback only; a
    /// LAN address of this same Mac is not recognised, which errs on the
    /// side of blocking).
    static func isOnThisComputer(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host?.lowercased() else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost"
            || bare.hasSuffix(".localhost")
            || bare == "::1"
            || bare.hasPrefix("127.")
    }
}
