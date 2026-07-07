import Foundation
import AVFoundation

class AudioPreprocessor {
    nonisolated(unsafe) static let shared = AudioPreprocessor()
    
    // Maximum file size (25 MB)
    // Berget accepts up to 100 MB per request and processes ~25x realtime
    // within its 30-minute cap, so hours of 16 kHz mono AAC fit in ONE
    // request. Single requests matter beyond efficiency: speaker labels
    // (SPEAKER_00...) are only consistent within one transcription, so
    // chunking would scramble diarization.
    private let maxFileSize: Int64 = 95 * 1024 * 1024
    
    // Maximum duration (10 minutes)
    private let maxDuration: Double = 6 * 60 * 60  // ~6h fits Berget's 30-min processing cap with margin
    
    // Chunk duration with overlap (9 minutes chunks with 30 seconds overlap)
    private let chunkDuration: Double = 540.0  // 9 minutes
    private let overlapDuration: Double = 30.0  // 30 seconds overlap
    
    struct ProcessedAudio {
        let url: URL
        let chunks: [AudioChunk]
        let needsCleanup: Bool
        let originalDuration: Double
        /// The user's original input file — never deleted by cleanup.
        let originalURL: URL
    }
    
    struct AudioChunk {
        let url: URL
        let startTime: Double
        let endTime: Double
        let index: Int
    }
    
    func preprocessAudio(
        url: URL,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessedAudio {
        onProgress?(NSLocalizedString("analyzing_audio_file", comment: ""))
        
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationInSeconds = CMTimeGetSeconds(duration)
        
        // Check file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0
        
        // Determine if we need to process the audio
        let needsConversion = !isOptimalFormat(url: url) || fileSize > maxFileSize
        let needsChunking = durationInSeconds > maxDuration || fileSize > maxFileSize
        
        if !needsConversion && !needsChunking {
            // Audio is already optimal
            return ProcessedAudio(
                url: url,
                chunks: [AudioChunk(url: url, startTime: 0, endTime: durationInSeconds, index: 0)],
                needsCleanup: false,
                originalDuration: durationInSeconds,
                originalURL: url
            )
        }

        // Convert to optimal format if needed
        var processedURL = url
        var needsCleanup = false

        if needsConversion {
            onProgress?(NSLocalizedString("converting_audio_format", comment: ""))
            processedURL = try await convertToOptimalFormat(url: url)
            needsCleanup = true
        }

        // Chunk if needed
        var chunks: [AudioChunk] = []
        if needsChunking {
            onProgress?(NSLocalizedString("splitting_audio_chunks", comment: ""))
            chunks = try await createChunks(url: processedURL, duration: durationInSeconds)
            // Chunks are always temporary files, even when no conversion happened
            needsCleanup = true
        } else {
            chunks = [AudioChunk(url: processedURL, startTime: 0, endTime: durationInSeconds, index: 0)]
        }

        return ProcessedAudio(
            url: processedURL,
            chunks: chunks,
            needsCleanup: needsCleanup,
            originalDuration: durationInSeconds,
            originalURL: url
        )
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
    func needsConversionForWhisperKit(url: URL) -> Bool {
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
    func extractAudioForWhisperKit(url: URL) async throws -> URL {
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
        
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        try await transferAudio(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            outputURL: outputURL
        )

        return outputURL
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
                // Only mutated on the serial queue below, so no lock is needed.
                var hasResumed = false
                writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.extraction")) {
                    guard !hasResumed else { return }
                    while writerInput.isReadyForMoreMediaData {
                        guard writer.status != .failed else {
                            hasResumed = true
                            continuation.resume(throwing: writer.error
                                ?? AudioProcessingError.exportFailed("Audio writer failed"))
                            return
                        }
                        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                            guard writerInput.append(sampleBuffer) else {
                                hasResumed = true
                                continuation.resume(throwing: writer.error
                                    ?? AudioProcessingError.exportFailed("Failed to append audio data"))
                                return
                            }
                        } else {
                            writerInput.markAsFinished()
                            hasResumed = true
                            continuation.resume()
                            return
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

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

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
    
    func cleanupProcessedAudio(_ processedAudio: ProcessedAudio) {
        guard processedAudio.needsCleanup else { return }

        // Delete temporary files — never the user's original file
        if processedAudio.url != processedAudio.originalURL {
            try? FileManager.default.removeItem(at: processedAudio.url)
        }

        for chunk in processedAudio.chunks where chunk.url != processedAudio.originalURL {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }
    
    func mergeChunkedTranscriptions(
        _ transcriptions: [(chunk: AudioChunk, result: TranscriptionResult)]
    ) -> TranscriptionResult {
        // Safety check
        guard !transcriptions.isEmpty else {
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
        var segmentId = 0
        
        for (index, (chunk, result)) in transcriptions.enumerated() {
            if index == 0 {
                // First chunk - use all text
                mergedText = result.text
                
                // Map segments with incremental IDs
                for segment in result.segments {
                    mergedSegments.append(TranscriptionSegment(
                        id: segmentId,
                        start: segment.start + chunk.startTime,
                        end: segment.end + chunk.startTime,
                        text: segment.text,
                        confidence: segment.confidence,
                        speaker: segment.speaker
                    ))
                    segmentId += 1
                }
            } else {
                // Subsequent chunks - remove overlap
                let overlapText = removeOverlap(
                    previousText: mergedText,
                    currentText: result.text,
                    overlapDuration: overlapDuration
                )
                
                if !overlapText.isEmpty {
                    mergedText += " " + overlapText
                }
                
                // Adjust segment timestamps
                for segment in result.segments {
                    // Skip segments in the overlap region
                    if segment.start >= overlapDuration {
                        mergedSegments.append(TranscriptionSegment(
                            id: segmentId,
                            start: segment.start + chunk.startTime,
                            end: segment.end + chunk.startTime,
                            text: segment.text,
                            confidence: segment.confidence,
                            speaker: segment.speaker
                        ))
                        segmentId += 1
                    }
                }
            }
        }
        
        // Use the first result as template and update with merged data
        let firstResult = transcriptions.first!.result
        return TranscriptionResult(
            text: mergedText.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: mergedSegments,
            language: firstResult.language,
            duration: transcriptions.map { $0.chunk.endTime - $0.chunk.startTime }.reduce(0, +),
            timestamp: Date(),
            modelUsed: firstResult.modelUsed
        )
    }
    
    private func removeOverlap(previousText: String, currentText: String, overlapDuration: Double) -> String {
        // Safety check for empty texts
        guard !previousText.isEmpty && !currentText.isEmpty else {
            return currentText
        }
        
        let previousWords = Array(previousText.split(separator: " ").suffix(50)) // Last 50 words
        let currentWords = Array(currentText.split(separator: " "))
        
        // Safety check for very short texts
        guard previousWords.count > 0 && currentWords.count > 0 else {
            return currentText
        }
        
        // Find where the overlap starts in the current text
        var bestMatch = 0
        var bestScore = 0
        
        // Look for matching sequences
        for i in 0..<min(50, currentWords.count) {
            var score = 0
            let maxJ = min(previousWords.count, min(currentWords.count - i, i + 1))
            
            for j in 0..<maxJ {
                // Bounds check
                let prevIndex = previousWords.count - 1 - j
                let currIndex = i - j
                
                if prevIndex >= 0 && prevIndex < previousWords.count &&
                   currIndex >= 0 && currIndex < currentWords.count {
                    if previousWords[prevIndex] == currentWords[currIndex] {
                        score += 1
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
            
            if score > bestScore {
                bestScore = score
                bestMatch = i
            }
        }
        
        // Return text after the overlap
        if bestMatch > 0 && bestScore > 5 { // Require at least 5 matching words
            // Safe array slicing
            if bestMatch < currentWords.count {
                return currentWords[bestMatch...].joined(separator: " ")
            } else {
                return ""
            }
        } else {
            // No good overlap found, return all text (might have some duplication)
            return currentWords.joined(separator: " ")
        }
    }
}

enum AudioProcessingError: LocalizedError {
    case exportFailed(String)
    case chunkingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .exportFailed(let message):
            return "Audio export failed: \(message)"
        case .chunkingFailed(let message):
            return "Audio chunking failed: \(message)"
        }
    }
}