import Foundation
import WhisperKit
import SpeakerKit
import os

/// A contiguous span of audio attributed to one speaker.
public struct SpeakerTurn: Sendable, Codable {
    public let speakerId: Int
    public let start: Double
    public let end: Double

    public init(speakerId: Int, start: Double, end: Double) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
    }
}

public enum DiarizationError: LocalizedError {
    case noAudio
    case localOnlyNoModels

    public var errorDescription: String? {
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
public final class DiarizationService {
    public static let shared = DiarizationService()

    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "Diarization")
    /// Set only once its models have loaded.
    private var speakerKit: SpeakerKit?
    /// The initialisation in flight, shared by every `diarize` call that
    /// arrives while it runs.
    private var initialization: Task<SpeakerKit, Error>?
    /// Options used by the most recent run, recorded into debug exports so
    /// tuning experiments are self-documenting.
    public private(set) var lastOptionsDescription = ""

    // MARK: - Models

    /// Every file that must be on disk for the speaker models to load, by
    /// the folder SpeakerKit downloads as a unit: the three models of the
    /// Pyannote pipeline in the variants SpeakerKit picks for this OS, and
    /// the compiled models it loads from each (PyannoteModelLoader.load).
    nonisolated static func requiredModelFiles(in repoDir: URL) -> [(folder: URL, files: [URL])] {
        let models: [(info: ModelInfo, names: [String])] = [
            (.segmenter(), ["SpeakerSegmenter"]),
            (.embedder(), ["SpeakerEmbedderPreprocessor", "SpeakerEmbedder"]),
            (.plda(), ["PldaProjector"]),
        ]
        return models.map { model in
            let folder = model.info.modelURL(baseURL: repoDir)
            let files = model.names.flatMap { name in
                ["weights/weight.bin", "model.mil", "coremldata.bin"].map {
                    folder.appendingPathComponent("\(name).mlmodelc").appendingPathComponent($0)
                }
            }
            return (folder, files)
        }
    }

    /// The model folders that are missing or lack files. A download that was
    /// interrupted leaves folders like that behind, so the existence of a
    /// folder says nothing about whether the models in it can be loaded.
    nonisolated static func incompleteModelFolders(in repoDir: URL) -> [URL] {
        requiredModelFiles(in: repoDir)
            .filter { model in !model.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
            .map(\.folder)
    }

    /// Returns SpeakerKit with its models loaded, creating it on first use.
    /// Calls that overlap share one initialisation.
    private func loadedSpeakerKit() async throws -> SpeakerKit {
        if let speakerKit { return speakerKit }
        if let initialization { return try await initialization.value }

        let task = Task { try await self.makeSpeakerKit() }
        initialization = task
        defer { initialization = nil }
        // Kept only if it loaded. A SpeakerKit that failed stays tied to the
        // model folder it was given; holding on to it would repeat the
        // failure on every later run instead of looking at the disk again.
        let kit = try await task.value
        speakerKit = kit
        return kit
    }

    private func makeSpeakerKit() async throws -> SpeakerKit {
        let downloadBase = ModelManager.shared.downloadBase
        let repoDir = downloadBase.appendingPathComponent("models/argmaxinc/speakerkit-coreml")

        // When the Pyannote models are already on disk, pin them via
        // modelFolder — the SDK then skips its Hub download/check
        // entirely, guaranteeing zero network for diarization.
        let incompleteFolders = Self.incompleteModelFolders(in: repoDir)
        let hasLocalModels = incompleteFolders.isEmpty
        if !hasLocalModels {
            if UserDefaults.standard.bool(forKey: "localOnlyMode") {
                throw DiarizationError.localOnlyNoModels
            }
            // SpeakerKit takes any non-empty model folder for a finished
            // download (ModelDownloader.patternsExistLocally) and would not
            // fetch what is missing from it. Removing the partial folders
            // makes it download them again.
            for folder in incompleteFolders {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        logger.info("Initializing SpeakerKit (local models: \(hasLocalModels))")
        let config = PyannoteConfig(
            downloadBase: downloadBase.path,
            modelFolder: hasLocalModels ? repoDir.path : nil
        )
        let kit = try await SpeakerKit(config)
        // Load here rather than on the first diarization, so that a failure
        // to load surfaces before the instance is kept.
        try await kit.ensureModelsLoaded()
        return kit
    }

    // MARK: - Diarization

    /// Diarizes an audio (or video) file and returns speaker turns ordered by
    /// start time. Downloads the diarization models on first use; they are
    /// stored under the same base directory as the Whisper models.
    public func diarize(
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

        let speakerKit = try await loadedSpeakerKit()

        let start = Date()
        // A known speaker count pins the clustering stage — significantly more
        // reliable on short clips where per-speaker samples are sparse.
        // Tuning experiment overrides (unset = SDK defaults; threshold 0.6):
        //   defaults write com.mickekring.transcribe.Transcribe diarizationClusterThreshold -float 0.7
        //   defaults write com.mickekring.transcribe.Transcribe diarizationMinClusterSize -int 3
        //   defaults write com.mickekring.transcribe.Transcribe diarizationExclusiveReconciliation -bool false
        let defaults = UserDefaults.standard
        let thresholdOverride = defaults.double(forKey: "diarizationClusterThreshold")
        let minClusterOverride = defaults.integer(forKey: "diarizationMinClusterSize")
        let exclusive = (defaults.object(forKey: "diarizationExclusiveReconciliation") as? Bool) ?? true
        let options = PyannoteDiarizationOptions(
            numberOfSpeakers: numberOfSpeakers,
            clusterDistanceThreshold: thresholdOverride > 0 ? Float(thresholdOverride) : nil,
            minClusterSize: minClusterOverride > 0 ? minClusterOverride : nil,
            useExclusiveReconciliation: exclusive
        )
        lastOptionsDescription = "speakers=\(numberOfSpeakers.map(String.init) ?? "auto") threshold=\(thresholdOverride > 0 ? String(thresholdOverride) : "default(0.6)") minCluster=\(minClusterOverride > 0 ? String(minClusterOverride) : "default") exclusive=\(exclusive)"
        logger.info("Diarizing with \(self.lastOptionsDescription, privacy: .public)")
        let result = try await speakerKit.diarize(audioArray: samples, options: options) { progress in
            onProgress?(progress.fractionCompleted)
        }
        logger.info("Diarization found \(result.speakerCount) speakers in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")

        let turns = result.segments
            .compactMap { segment -> SpeakerTurn? in
                guard let id = segment.speaker.speakerId else { return nil }
                return SpeakerTurn(
                    speakerId: id,
                    start: Double(segment.startTime),
                    end: Double(segment.endTime)
                )
            }
            .sorted { $0.start < $1.start }

        // Auto mode only: dissolve phantom speakers. Rapid exchanges blend
        // both voices into every embedding window; those chimera windows
        // cluster together as a "new voice" (observed: a 12s closing volley
        // in a 4-minute two-person clip becoming speaker 3). A speaker with
        // a sliver of total time is debris, not a participant — merge into
        // the temporally adjacent speaker. A pinned count is never altered.
        guard numberOfSpeakers == nil else { return turns }
        return Self.dissolvePhantomSpeakers(turns, logger: logger)
    }

    /// Merges speakers with < 5% of speech time (and < 20s absolute) into
    /// whichever real speaker holds the most time adjacent to their turns.
    private static func dissolvePhantomSpeakers(_ turns: [SpeakerTurn], logger: Logger) -> [SpeakerTurn] {
        var result = turns
        while true {
            var timeBySpeaker: [Int: Double] = [:]
            for turn in result {
                timeBySpeaker[turn.speakerId, default: 0] += turn.end - turn.start
            }
            guard timeBySpeaker.count > 1 else { return result }
            let totalTime = timeBySpeaker.values.reduce(0, +)

            // Contiguity guard: chimera clusters come from ONE blended
            // passage, so a phantom's turns are temporally contiguous. A real
            // quiet participant (validated: a girl with 4.3s across 47s of
            // interview) peppers the conversation — never dissolved, however
            // small her share.
            func isContiguous(_ speaker: Int) -> Bool {
                let speakerTurns = result.filter { $0.speakerId == speaker }
                guard let first = speakerTurns.first, let last = speakerTurns.last else { return false }
                return last.end - first.start <= 30.0
            }
            guard let phantom = timeBySpeaker
                .filter({ $0.value < 20.0 && $0.value / totalTime < 0.05 && isContiguous($0.key) })
                .min(by: { $0.value < $1.value })?.key else { return result }

            // Adjacent speaker: most speech time in the turns bordering the
            // phantom's spans
            var adjacency: [Int: Double] = [:]
            for (index, turn) in result.enumerated() where turn.speakerId == phantom {
                for neighborIndex in [index - 1, index + 1] {
                    guard result.indices.contains(neighborIndex) else { continue }
                    let neighbor = result[neighborIndex]
                    if neighbor.speakerId != phantom {
                        adjacency[neighbor.speakerId, default: 0] += neighbor.end - neighbor.start
                    }
                }
            }
            let heir = adjacency.max(by: { $0.value < $1.value })?.key
                ?? timeBySpeaker.filter { $0.key != phantom }.max(by: { $0.value < $1.value })!.key

            logger.info("Dissolving phantom speaker \(phantom) (\(timeBySpeaker[phantom] ?? 0, format: .fixed(precision: 1))s) into speaker \(heir)")
            result = result.map { turn in
                turn.speakerId == phantom
                    ? SpeakerTurn(speakerId: heir, start: turn.start, end: turn.end)
                    : turn
            }
        }
    }
}
