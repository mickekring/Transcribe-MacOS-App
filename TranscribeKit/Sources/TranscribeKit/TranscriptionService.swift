import Foundation
import Combine

// Transcription update structure for streaming
public struct TranscriptionUpdate {
    public let text: String
    public let progress: Double
    public let segments: [TranscriptionSegmentData]
    public let isComplete: Bool

    /// Updates below this progress carry a status message ("Loading model…")
    /// in `text`; from here up, `text` is the transcript so far.
    public static let contentProgressFloor = 0.15

    /// How many unread updates a transcription stream holds before it starts
    /// replacing the oldest (`.bufferingNewest`).
    ///
    /// Every update is a complete snapshot — the whole text so far, not a
    /// delta — so a reader that falls behind loses nothing by skipping ahead,
    /// and the unbounded default only let full copies of a growing transcript
    /// pile up behind a slow reader. What must arrive still does:
    /// - the final `isComplete` update is the last element yielded, and this
    ///   policy only ever evicts the oldest one, so it cannot be dropped;
    /// - status messages all precede the first content update, and content
    ///   is throttled to five a second, so one is only evicted once the
    ///   reader has left this many newer updates unread — seconds of not
    ///   reading, after which that status is no longer the state to show.
    static let streamBufferLimit = 16
}

@MainActor
public class TranscriptionService {
    public init() {}

    private let modelManager = ModelManager.shared
    private let languageManager = LanguageManager.shared
    private var transcriptionTask: Task<Void, Never>?

    public func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(TranscriptionUpdate.streamBufferLimit)) { continuation in
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
            // terminates the engine's stream and stops its inference.
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

        // Cancelled during the conversion: don't start an engine at all
        try Task.checkCancellation()

        // Both engines produce the same update stream. The shared services
        // keep the loaded model alive across transcriptions and coalesce
        // concurrent loads instead of letting them compete.
        let updates: AsyncThrowingStream<TranscriptionUpdate, Error>
        if ModelManager.engine(for: modelId) == .parakeet {
            updates = ParakeetService.shared.transcribe(fileURL: audioURL, modelId: modelId, language: selectedLanguage)
        } else {
            updates = WhisperKitService.shared.transcribe(fileURL: audioURL, modelId: modelId, language: selectedLanguage)
        }

        for try await update in updates {
            continuation.yield(update)

            if update.isComplete {
                continuation.finish()
                return
            }
        }

        // A cancelled task leaves the loop above without an error (the
        // engine's stream just ends). That is not a transcription that
        // finished: report it as the cancellation it was.
        try Task.checkCancellation()

        // If the loop exits without isComplete, still finish the stream
        continuation.finish()
    }

    /// Cancels the transcription this instance started — and only that one.
    ///
    /// Cancelling the task is all it takes, for either engine: its for-await
    /// over the engine's stream ends, the stream's termination handler runs,
    /// and that handler stops the run that feeds it (WhisperKitService
    /// cancels its producer and sets the flag its decoding callback checks;
    /// ParakeetService cancels its producer task). Going through the shared
    /// services instead would cancel whichever transcription registered
    /// with them last, which may be another view's.
    public func cancelTranscription() {
        transcriptionTask?.cancel()
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
