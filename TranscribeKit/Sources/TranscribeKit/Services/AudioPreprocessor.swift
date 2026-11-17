import Foundation
import AVFoundation
import os

public class AudioPreprocessor {
    nonisolated(unsafe) public static let shared = AudioPreprocessor()

    // Maximum upload size.
    // Berget accepts up to 100 MB per request and processes ~25x realtime
    // within its 30-minute cap, so hours of 16 kHz mono AAC fit in ONE
    // request. Single requests matter beyond efficiency: speaker labels
    // (SPEAKER_00...) are only consistent within one transcription, so
    // chunking would scramble diarization.
    private let maxFileSize: Int64

    // Maximum duration of one upload
    private let maxDuration: Double  // ~6h fits Berget's 30-min processing cap with margin

    // Chunk duration with overlap (9 minutes chunks with 30 seconds overlap)
    private let chunkDuration: Double
    private let overlapDuration: Double

    /// The defaults are the limits of the service; tests pass small ones so a
    /// few seconds of audio exercise the same decisions as hours of it.
    init(
        maxFileSize: Int64 = 95 * 1024 * 1024,
        maxDuration: Double = 6 * 60 * 60,
        chunkDuration: Double = 540.0,
        overlapDuration: Double = 30.0
    ) {
        self.maxFileSize = maxFileSize
        self.maxDuration = maxDuration
        self.chunkDuration = chunkDuration
        self.overlapDuration = overlapDuration
    }

    public struct ProcessedAudio {
        public let url: URL
        public let chunks: [AudioChunk]
        public let needsCleanup: Bool
        public let originalDuration: Double
        /// The user's original input file — never deleted by cleanup.
        public let originalURL: URL
    }
    
    public struct AudioChunk {
        public let url: URL
        public let startTime: Double
        public let endTime: Double
        public let index: Int
    }
    
    public func preprocessAudio(
        url: URL,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessedAudio {
        onProgress?(localized("analyzing_audio_file"))

        let durationInSeconds = try await Self.duration(of: url)
        let fileSize = try Self.fileSize(of: url)

        // Convert to the compact upload format unless the file already is one
        // the service takes and is small enough to send as it is
        let needsConversion = !isOptimalFormat(url: url) || fileSize > maxFileSize

        var processedURL = url
        var needsCleanup = false

        if needsConversion {
            onProgress?(localized("converting_audio_format"))
            processedURL = try await convertToOptimalFormat(url: url)
            needsCleanup = true
        }

        do {
            // Whether to split is decided by what will be uploaded, not by
            // the file the user picked: an hour of video or of 48 kHz stereo
            // WAV is hundreds of megabytes but some 15 MB once converted.
            // Splitting it anyway would cost the consistent speaker labels
            // that only a single request gives.
            let uploadDuration = needsConversion ? try await Self.duration(of: processedURL) : durationInSeconds
            let uploadSize = needsConversion ? try Self.fileSize(of: processedURL) : fileSize
            let needsChunking = uploadDuration > maxDuration || uploadSize > maxFileSize

            let chunks: [AudioChunk]
            if needsChunking {
                onProgress?(localized("splitting_audio_chunks"))
                chunks = try await createChunks(url: processedURL, duration: uploadDuration)
                // Chunks are always temporary files, even when no conversion happened
                needsCleanup = true
            } else {
                chunks = [AudioChunk(url: processedURL, startTime: 0, endTime: uploadDuration, index: 0)]
            }

            return ProcessedAudio(
                url: processedURL,
                chunks: chunks,
                needsCleanup: needsCleanup,
                originalDuration: durationInSeconds,
                originalURL: url
            )
        } catch {
            // The caller never gets a ProcessedAudio to clean up
            if needsConversion {
                try? FileManager.default.removeItem(at: processedURL)
            }
            throw error
        }
    }

    private static func duration(of url: URL) async throws -> Double {
        CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    /// Audio-only formats that WhisperKit/ExtAudioFile can read directly.
    private static let nativeAudioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "flac", "aac", "aif", "aiff", "caf"
    ]
    
    /// Returns true when the file is already in a format WhisperKit can consume
    /// without conversion **and** its size is within the Berget upload limit.
    private func isOptimalFormat(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard Self.nativeAudioExtensions.contains(ext) else { return false }
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = fileAttributes?[.size] as? Int64 ?? 0
        return fileSize < maxFileSize
    }
    
    /// Returns true when the file needs to be converted before WhisperKit can
    /// read it (e.g. video containers like .mp4/.mov, or non-native audio).
    public func needsConversionForWhisperKit(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !Self.nativeAudioExtensions.contains(ext)
    }

    /// Directory for preprocessing temp files. Lives under
    /// `temporaryDirectory/Transcribe/` so `AppDelegate.cleanupTemporaryFiles()`
    /// removes force-quit leftovers at next launch.
    private func preprocessingTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcribe")
            .appendingPathComponent("Preprocessing")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// Extracts audio from any AVAsset-compatible file (including video) and
    /// returns a .wav URL that WhisperKit can read. Caller must delete the
    /// returned file when done.
    public func extractAudioForWhisperKit(url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioProcessingError.exportFailed("No audio track found in file")
        }

        let outputURL = try preprocessingTempDirectory()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        // Use AVAssetReader + AVAssetWriter for reliable extraction from any container
        let reader = try AVAssetReader(asset: asset)
        
        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
        guard reader.canAdd(readerOutput) else {
            throw AudioProcessingError.exportFailed("Cannot read audio track")
        }
        reader.add(readerOutput)
        
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        
        let writerInputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerInputSettings)
        guard writer.canAdd(writerInput) else {
            throw AudioProcessingError.exportFailed("Cannot configure audio writer")
        }
        writer.add(writerInput)

        try Self.start(reader: reader, writer: writer, sessionStart: .zero, outputURL: outputURL)

        try await transferAudio(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            outputURL: outputURL
        )

        return outputURL
    }

    /// Starts the reader and the writer. Both report failure through their
    /// return value rather than by throwing, and starting a session on a
    /// writer that did not start raises an Objective-C exception.
    private static func start(reader: AVAssetReader, writer: AVAssetWriter, sessionStart: CMTime, outputURL: URL) throws {
        guard reader.startReading() else {
            throw AudioProcessingError.exportFailed(
                reader.error?.localizedDescription ?? "Cannot start reading audio")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            // The writer may have created its output file before failing
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioProcessingError.exportFailed(
                writer.error?.localizedDescription ?? "Cannot start writing audio")
        }
        writer.startSession(atSourceTime: sessionStart)
    }

    /// What the pump in `transferAudio` works on. AVFoundation calls the pump
    /// on another queue and none of these types is Sendable, so the pump
    /// reaches them through a lock instead of capturing them bare: the lock,
    /// not a comment about which queue runs what, is what makes each call
    /// see the state the previous one left.
    private struct TransferState {
        let readerOutput: AVAssetReaderTrackOutput
        let writer: AVAssetWriter
        let writerInput: AVAssetWriterInput
        var hasResumed = false
    }

    /// Pumps all sample buffers from `readerOutput` into `writerInput`, then
    /// finishes writing and validates both reader and writer state. The
    /// continuation is resumed exactly once on every path (success, writer
    /// failure mid-stream, or reader failure). Removes any partial output
    /// file before rethrowing.
    private func transferAudio(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        outputURL: URL
    ) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let transfer = OSAllocatedUnfairLock(uncheckedState: TransferState(
                    readerOutput: readerOutput,
                    writer: writer,
                    writerInput: writerInput
                ))
                writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.extraction")) {
                    transfer.withLockUnchecked { state in
                        guard !state.hasResumed else { return }
                        while state.writerInput.isReadyForMoreMediaData {
                            guard state.writer.status != .failed else {
                                state.hasResumed = true
                                continuation.resume(throwing: state.writer.error
                                    ?? AudioProcessingError.exportFailed("Audio writer failed"))
                                return
                            }
                            if let sampleBuffer = state.readerOutput.copyNextSampleBuffer() {
                                guard state.writerInput.append(sampleBuffer) else {
                                    state.hasResumed = true
                                    continuation.resume(throwing: state.writer.error
                                        ?? AudioProcessingError.exportFailed("Failed to append audio data"))
                                    return
                                }
                            } else {
                                state.writerInput.markAsFinished()
                                state.hasResumed = true
                                continuation.resume()
                                return
                            }
                        }
                    }
                }
            }

            await writer.finishWriting()

            // A nil sample buffer with a failed reader means the source was
            // truncated/corrupt mid-decode — not EOF. Don't return partial audio.
            if reader.status == .failed {
                throw AudioProcessingError.exportFailed(
                    reader.error?.localizedDescription ?? "Failed to read source audio")
            }

            guard writer.status == .completed else {
                throw AudioProcessingError.exportFailed(
                    writer.error?.localizedDescription ?? "Audio extraction failed")
            }
        } catch {
            if reader.status == .reading {
                reader.cancelReading()
            }
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
    
    private func convertToOptimalFormat(url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)

        let outputURL = try preprocessingTempDirectory()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        try await encodeCompactMonoM4A(asset: asset, timeRange: nil, outputURL: outputURL)
        return outputURL
    }

    /// Re-encodes (a time range of) an asset's audio track to mono 16 kHz AAC
    /// (~32 kbps) so files fit under the Berget upload limit. This performs a
    /// real downmix and bitrate reduction, unlike the previous AVAudioMix-based
    /// approach which was a no-op.
    private func encodeCompactMonoM4A(asset: AVAsset, timeRange: CMTimeRange?, outputURL: URL) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioProcessingError.exportFailed("No audio track found in file")
        }

        let reader = try AVAssetReader(asset: asset)
        if let timeRange {
            reader.timeRange = timeRange
        }

        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
        guard reader.canAdd(readerOutput) else {
            throw AudioProcessingError.exportFailed("Cannot read audio track")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        let writerInputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerInputSettings)
        guard writer.canAdd(writerInput) else {
            throw AudioProcessingError.exportFailed("Cannot configure audio writer")
        }
        writer.add(writerInput)

        try Self.start(reader: reader, writer: writer, sessionStart: timeRange?.start ?? .zero, outputURL: outputURL)

        try await transferAudio(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            outputURL: outputURL
        )
    }

    private func createChunks(url: URL, duration: Double) async throws -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        let asset = AVURLAsset(url: url)

        var currentStart: Double = 0
        var chunkIndex = 0

        while currentStart < duration {
            let chunkEnd = min(currentStart + chunkDuration, duration)

            // Create chunk URL - use m4a format
            let chunkURL = try preprocessingTempDirectory()
                .appendingPathComponent("chunk_\(chunkIndex)_\(UUID().uuidString)")
                .appendingPathExtension("m4a")

            let startTime = CMTime(seconds: currentStart, preferredTimescale: 1000)
            let endTime = CMTime(seconds: chunkEnd, preferredTimescale: 1000)
            let timeRange = CMTimeRange(start: startTime, end: endTime)

            do {
                try await encodeCompactMonoM4A(asset: asset, timeRange: timeRange, outputURL: chunkURL)
            } catch {
                // Don't leak chunks that were already written
                for chunk in chunks {
                    try? FileManager.default.removeItem(at: chunk.url)
                }
                throw AudioProcessingError.chunkingFailed(
                    "Failed to export chunk \(chunkIndex): \(error.localizedDescription)")
            }

            chunks.append(AudioChunk(
                url: chunkURL,
                startTime: currentStart,
                endTime: chunkEnd,
                index: chunkIndex
            ))

            // Move to next chunk with overlap
            currentStart = chunkEnd - overlapDuration
            chunkIndex += 1

            // Avoid infinite loop for very short files
            if chunkEnd >= duration {
                break
            }
        }

        return chunks
    }
    
    public func cleanupProcessedAudio(_ processedAudio: ProcessedAudio) {
        guard processedAudio.needsCleanup else { return }

        // Delete temporary files — never the user's original file
        if processedAudio.url != processedAudio.originalURL {
            try? FileManager.default.removeItem(at: processedAudio.url)
        }

        for chunk in processedAudio.chunks where chunk.url != processedAudio.originalURL {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }
    
    /// Joins the transcriptions of consecutive, overlapping chunks into one
    /// result on the timeline of the whole file.
    ///
    /// Each chunk after the first repeats the end of the one before it; the
    /// repeated part is taken from the earlier chunk and cut from the later
    /// one. Word timings are carried along. Speaker labels are carried as
    /// they are, but they are numbered per request and so do not identify
    /// the same person across chunks.
    public func mergeChunkedTranscriptions(
        _ transcriptions: [(chunk: AudioChunk, result: TranscriptionResult)]
    ) -> TranscriptionResult {
        guard let firstResult = transcriptions.first?.result else {
            return TranscriptionResult(
                text: "",
                segments: [],
                language: "unknown",
                duration: 0,
                timestamp: Date(),
                modelUsed: "unknown"
            )
        }

        var mergedText = ""
        var mergedSegments: [TranscriptionSegment] = []

        func appendText(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            mergedText += mergedText.isEmpty ? text : " " + text
        }

        for (index, (chunk, result)) in transcriptions.enumerated() {
            // How much of the start of this chunk the previous one already
            // covers. Taken from the chunks themselves rather than assumed:
            // when the chunk before this one is missing (it failed), nothing
            // of this one has been transcribed yet and nothing may be cut.
            let overlap = index == 0 ? 0 : max(0, transcriptions[index - 1].chunk.endTime - chunk.startTime)

            guard !result.segments.isEmpty else {
                // No timings to go by: find the repeated words instead
                appendText(overlap > 0
                    ? Self.removeOverlap(previousText: mergedText, currentText: result.text, overlapDuration: overlap)
                    : result.text)
                continue
            }

            // The text is built from the segments that are kept, so the two
            // cannot disagree about what the overlap was.
            for segment in result.segments {
                guard let kept = Self.trimming(segment, toStartAfter: overlap, previousText: mergedText) else { continue }
                mergedSegments.append(TranscriptionSegment(
                    id: mergedSegments.count,
                    start: kept.start + chunk.startTime,
                    end: kept.end + chunk.startTime,
                    text: kept.text,
                    confidence: kept.confidence,
                    speaker: kept.speaker,
                    words: kept.words?.map { word in
                        TranscriptionWord(
                            word: word.word,
                            start: word.start + chunk.startTime,
                            end: word.end + chunk.startTime,
                            speaker: word.speaker
                        )
                    }
                ))
                appendText(kept.text)
            }
        }

        return TranscriptionResult(
            text: mergedText,
            segments: mergedSegments,
            language: firstResult.language,
            duration: transcriptions.map { $0.chunk.endTime - $0.chunk.startTime }.reduce(0, +),
            timestamp: Date(),
            modelUsed: firstResult.modelUsed
        )
    }

    /// The part of a segment that lies after the first `overlap` seconds of
    /// its chunk — the part the previous chunk has not already transcribed —
    /// or nil when there is none. Times stay relative to the chunk.
    ///
    /// A segment that starts inside the overlap and ends after it is cut, not
    /// dropped: dropping it loses the words spoken after the overlap, which
    /// no other chunk has.
    static func trimming(_ segment: TranscriptionSegment, toStartAfter overlap: Double, previousText: String) -> TranscriptionSegment? {
        guard overlap > 0, segment.start < overlap else { return segment }
        guard segment.end > overlap else { return nil }

        if let words = segment.words, !words.isEmpty {
            // A word belongs to the chunk that heard most of it
            let kept = words.filter { ($0.start + $0.end) / 2 >= overlap }
            guard let firstKept = kept.first else { return nil }
            guard kept.count < words.count else { return segment }
            return TranscriptionSegment(
                id: segment.id,
                start: firstKept.start,
                end: segment.end,
                text: kept.map { $0.word.trimmingCharacters(in: .whitespaces) }.joined(separator: " "),
                confidence: segment.confidence,
                speaker: segment.speaker,
                words: kept
            )
        }

        // No word timings to cut at: drop the words it repeats instead
        let fullText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = removeOverlap(previousText: previousText, currentText: fullText, overlapDuration: overlap)
        guard !text.isEmpty else { return nil }
        return TranscriptionSegment(
            id: segment.id,
            start: text == fullText ? segment.start : overlap,
            end: segment.end,
            text: text,
            confidence: segment.confidence,
            speaker: segment.speaker,
            words: nil
        )
    }

    /// An upper bound on how fast people talk, for sizing the search below.
    /// Conversation runs at two to three words a second.
    private static let maxWordsPerSecond = 6.0

    /// Returns `currentText` without the words at its start that repeat the
    /// end of `previousText`, for two transcriptions whose audio overlaps by
    /// `overlapDuration` seconds. When no repetition is found the text is
    /// returned whole — duplicated words are better than lost ones.
    static func removeOverlap(previousText: String, currentText: String, overlapDuration: Double) -> String {
        let currentWords = currentText.split(separator: " ")
        guard !previousText.isEmpty, !currentWords.isEmpty else {
            return currentText
        }

        // The repetition ends somewhere within the words spoken in
        // `overlapDuration` seconds, so that is how far to look — and how
        // much of the previous text can take part in a match. (A fixed 50
        // words is some 20 seconds of speech: with a 30-second overlap the
        // end of the repetition was never inside the search.)
        let window = Int((overlapDuration * maxWordsPerSecond).rounded(.up))
        let previousWords = previousText.split(separator: " ").suffix(window)

        // For each position in the current text, count how many words ending
        // there equal the last words of the previous text. The longest such
        // run marks the end of the repetition.
        var lastRepeatedIndex = 0
        var bestScore = 0
        for index in 0..<min(window, currentWords.count) {
            var score = 0
            while score <= index, score < previousWords.count,
                  previousWords[previousWords.endIndex - 1 - score] == currentWords[index - score] {
                score += 1
            }
            if score > bestScore {
                bestScore = score
                lastRepeatedIndex = index
            }
        }

        // A few words in common are coincidence, not an overlap
        guard bestScore > 5 else {
            return currentWords.joined(separator: " ")
        }
        // The new text starts after the last repeated word
        return currentWords[(lastRepeatedIndex + 1)...].joined(separator: " ")
    }
}

public enum AudioProcessingError: LocalizedError {
    case exportFailed(String)
    case chunkingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .exportFailed(let message):
            return "Audio export failed: \(message)"
        case .chunkingFailed(let message):
            return "Audio chunking failed: \(message)"
        }
    }
}