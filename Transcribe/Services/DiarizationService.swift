import Foundation
import WhisperKit
import SpeakerKit
import os

/// A contiguous span of audio attributed to one speaker.
struct SpeakerTurn: Sendable {
    let speakerId: Int
    let start: Double
    let end: Double
}

enum DiarizationError: LocalizedError {
    case noAudio
    case localOnlyNoModels

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "No audio could be loaded for speaker identification."
        case .localOnlyNoModels:
            return "Local-only mode is enabled and the speaker models aren't downloaded yet. Turn it off in Settings once to download them."
        }
    }
}

/// Speaker diarization via SpeakerKit (Pyannote CoreML models).
/// Shared instance so the loaded models persist across runs, mirroring
/// WhisperKitService.
@MainActor
final class DiarizationService {
    static let shared = DiarizationService()

    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "Diarization")
    private var speakerKit: SpeakerKit?

    /// Diarizes an audio (or video) file and returns speaker turns ordered by
    /// start time. Downloads the diarization models on first use; they are
    /// stored under the same base directory as the Whisper models.
    func diarize(
        fileURL: URL,
        numberOfSpeakers: Int? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SpeakerTurn] {
        // Video containers / non-native formats: extract the audio track first,
        // same as the transcription pipeline does.
        let preprocessor = AudioPreprocessor.shared
        var audioURL = fileURL
        var cleanupTemp = false
        if preprocessor.needsConversionForWhisperKit(url: fileURL) {
            audioURL = try await preprocessor.extractAudioForWhisperKit(url: fileURL)
            cleanupTemp = true
        }
        defer {
            if cleanupTemp {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        // Resample to the 16 kHz mono float samples SpeakerKit expects,
        // off the main thread — this can take a while for long recordings.
        let path = audioURL.path
        let samples = try await Task.detached(priority: .userInitiated) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }.value
        guard !samples.isEmpty else { throw DiarizationError.noAudio }

        if speakerKit == nil {
            // When the Pyannote models are already on disk, pin them via
            // modelFolder — the SDK then skips its Hub download/check
            // entirely, guaranteeing zero network for diarization.
            let repoDir = ModelManager.shared.downloadBase
                .appendingPathComponent("models/argmaxinc/speakerkit-coreml")
            let hasLocalModels = FileManager.default.fileExists(
                atPath: repoDir.appendingPathComponent("speaker_segmenter").path
            )
            if !hasLocalModels && UserDefaults.standard.bool(forKey: "localOnlyMode") {
                throw DiarizationError.localOnlyNoModels
            }
            logger.info("Initializing SpeakerKit (local models: \(hasLocalModels))")
            let config = PyannoteConfig(
                downloadBase: ModelManager.shared.downloadBase.path,
                modelFolder: hasLocalModels ? repoDir.path : nil
            )
            speakerKit = try await SpeakerKit(config)
        }
        guard let speakerKit else { throw DiarizationError.noAudio }

        let start = Date()
        // A known speaker count pins the clustering stage — significantly more
        // reliable on short clips where per-speaker samples are sparse.
        let options = PyannoteDiarizationOptions(numberOfSpeakers: numberOfSpeakers)
        let result = try await speakerKit.diarize(audioArray: samples, options: options) { progress in
            onProgress?(progress.fractionCompleted)
        }
        logger.info("Diarization found \(result.speakerCount) speakers in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")

        return result.segments
            .compactMap { segment -> SpeakerTurn? in
                guard let id = segment.speaker.speakerId else { return nil }
                return SpeakerTurn(
                    speakerId: id,
                    start: Double(segment.startTime),
                    end: Double(segment.endTime)
                )
            }
            .sorted { $0.start < $1.start }
    }
}
