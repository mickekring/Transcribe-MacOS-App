import Foundation
import Combine

// Transcription update structure for streaming
struct TranscriptionUpdate {
    let text: String
    let progress: Double
    let segments: [TranscriptionSegmentData]
    let isComplete: Bool
}

@MainActor
class TranscriptionService {
    private let modelManager = ModelManager.shared
    private let languageManager = LanguageManager.shared
    private var whisperKitService: WhisperKitService?
    private var transcriptionTask: Task<Void, Never>?

    func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Check if we have a downloaded model
                    guard let selectedModel = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
                          !selectedModel.isEmpty else {
                        throw TranscriptionError.noModelSelected
                    }

                    if selectedModel.starts(with: "kb_whisper-") ||  // KB CoreML models
                       selectedModel.starts(with: "nb_whisper-") ||  // NB Whisper CoreML models
                       selectedModel.starts(with: "openai_whisper-") {
                        // Use WhisperKit for standard Whisper models and KB CoreML models
                        try await transcribeWithWhisperKit(
                            fileURL: fileURL,
                            modelId: selectedModel,
                            continuation: continuation
                        )
                    } else {
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
    
    private func transcribeWithWhisperKit(
        fileURL: URL,
        modelId: String,
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async throws {
        // Use the shared service so the loaded model persists across
        // transcriptions and concurrent loads coalesce instead of competing.
        if whisperKitService == nil {
            whisperKitService = WhisperKitService.shared
        }
        
        // Use WhisperKit for standard models
        guard let service = whisperKitService else {
            throw TranscriptionError.modelNotFound
        }
        
        // If the file is a video container or non-native audio format,
        // extract the audio track to a temporary .m4a first.
        let preprocessor = AudioPreprocessor.shared
        let needsConversion = preprocessor.needsConversionForWhisperKit(url: fileURL)
        var audioURL = fileURL
        
        if needsConversion {
            continuation.yield(TranscriptionUpdate(
                text: NSLocalizedString("converting_audio_format", comment: ""),
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
        
        // Stream transcription updates with model and language
        for try await update in service.transcribe(fileURL: audioURL, modelId: modelId, language: selectedLanguage) {
            continuation.yield(update)
            
            if update.isComplete {
                continuation.finish()
                return
            }
        }
        
        // If the loop exits without isComplete, still finish the stream
        continuation.finish()
    }
    
    func cancelTranscription() {
        transcriptionTask?.cancel()
        whisperKitService?.cancelTranscription()
    }
}

enum TranscriptionError: LocalizedError {
    case noModelSelected
    case modelNotFound
    case unsupportedModel
    
    var errorDescription: String? {
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