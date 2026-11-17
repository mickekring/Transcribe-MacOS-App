import Foundation
import Combine

// Transcription update structure for streaming
public struct TranscriptionUpdate {
    public let text: String
    public let progress: Double
    public let segments: [TranscriptionSegmentData]
    public let isComplete: Bool
}

@MainActor
public class TranscriptionService {
    public init() {}

    private let modelManager = ModelManager.shared
    private let languageManager = LanguageManager.shared
    private var whisperKitService: WhisperKitService?
    private var transcriptionTask: Task<Void, Never>?

    public func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Check if we have a downloaded model
                    guard let selectedModel = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
                          !selectedModel.isEmpty else {
                        throw TranscriptionError.noModelSelected
                    }

                    switch ModelManager.engine(for: selectedModel) {
                    case .whisperKit, .parakeet:
                        try await transcribeLocally(
                            fileURL: fileURL,
                            modelId: selectedModel,
                            continuation: continuation
                        )
                    case .cloud, .none:
                        // Cloud models are driven by the caller (upload + chunking)
                        throw TranscriptionError.unsupportedModel
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            self.transcriptionTask = task

            // Cancelling this task ends the inner for-await loop, which
            // terminates the WhisperKitService stream and stops inference.
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    private func transcribeLocally(
        fileURL: URL,
        modelId: String,
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async throws {
        // If the file is a video container or non-native audio format,
        // extract the audio track to a temporary .m4a first.
        let preprocessor = AudioPreprocessor.shared
        let needsConversion = preprocessor.needsConversionForWhisperKit(url: fileURL)
        var audioURL = fileURL
        
        if needsConversion {
            continuation.yield(TranscriptionUpdate(
                text: localized("converting_audio_format"),
                progress: 0.02,
                segments: [],
                isComplete: false
            ))
            audioURL = try await preprocessor.extractAudioForWhisperKit(url: fileURL)
        }
        
        defer {
            // Clean up the temporary file if we created one
            if needsConversion {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        
        // Get the selected language
        let selectedLanguage = languageManager.selectedLanguage.code
        
        // Both engines produce the same update stream. The shared services
        // keep the loaded model alive across transcriptions and coalesce
        // concurrent loads instead of letting them compete.
        let updates: AsyncThrowingStream<TranscriptionUpdate, Error>
        if ModelManager.engine(for: modelId) == .parakeet {
            updates = ParakeetService.shared.transcribe(fileURL: audioURL, modelId: modelId, language: selectedLanguage)
        } else {
            whisperKitService = WhisperKitService.shared
            updates = WhisperKitService.shared.transcribe(fileURL: audioURL, modelId: modelId, language: selectedLanguage)
        }

        for try await update in updates {
            continuation.yield(update)
            
            if update.isComplete {
                continuation.finish()
                return
            }
        }
        
        // If the loop exits without isComplete, still finish the stream
        continuation.finish()
    }
    
    public func cancelTranscription() {
        transcriptionTask?.cancel()
        whisperKitService?.cancelTranscription()
    }
}

public enum TranscriptionError: LocalizedError {
    case noModelSelected
    case modelNotFound
    case unsupportedModel
    
    public var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No transcription model selected"
        case .modelNotFound:
            return "Selected model not found. Please download it first."
        case .unsupportedModel:
            return "Unsupported model type"
        }
    }
}

/// Engine-agnostic entry points for local model management. Views call these
/// instead of a specific runtime's service, so a model id is always handled
/// by the engine that owns it.
@MainActor
public enum LocalModels {
    /// Downloads a model without loading it.
    public static func download(modelId: String) async throws {
        switch ModelManager.engine(for: modelId) {
        case .parakeet: try await ParakeetService.shared.downloadOnly(modelId: modelId)
        case .whisperKit: try await WhisperKitService.shared.downloadOnly(modelId: modelId)
        case .cloud, .none: throw TranscriptionError.unsupportedModel
        }
    }

    public static func cancelDownload(modelId: String) {
        switch ModelManager.engine(for: modelId) {
        case .parakeet: ParakeetService.shared.cancelDownload(modelId: modelId)
        case .whisperKit: WhisperKitService.shared.cancelDownload(modelId: modelId)
        case .cloud, .none: break
        }
    }

    /// Loads the selected model in the background at launch, if it is local
    /// and already downloaded.
    public static func prewarmSelectedModel() {
        guard let modelId = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"), !modelId.isEmpty else { return }
        switch ModelManager.engine(for: modelId) {
        case .parakeet: ParakeetService.shared.prewarm(modelId: modelId)
        case .whisperKit: WhisperKitService.shared.prewarmSelectedModel()
        case .cloud, .none: break
        }
    }

    /// Frees every loaded local model.
    public static func unloadAll() {
        WhisperKitService.shared.unloadModel()
        ParakeetService.shared.unloadModel()
    }
}
