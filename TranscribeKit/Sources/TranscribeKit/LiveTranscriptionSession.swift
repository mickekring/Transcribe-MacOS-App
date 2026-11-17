import Foundation
import FluidAudio
import os

/// A word with its position on the recording's timeline (seconds).
public struct LiveWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What the live transcript looks like right now.
public struct LiveTranscriptUpdate: Sendable, Equatable {
    /// Text that will not change any more.
    public let confirmed: String
    /// Text for the audio still being re-decoded; expect it to be revised.
    public let volatile: String
    /// Seconds of audio the session has received.
    public let audioSeconds: Double

    public var isEmpty: Bool { confirmed.isEmpty && volatile.isEmpty }
}

/// How hard a live session is working — for tuning and diagnostics.
public struct LiveTranscriptionStats: Sendable, Equatable {
    /// Number of times the open segment was decoded.
    public var decodes = 0
    public var totalDecodeSeconds: TimeInterval = 0
    public var slowestDecodeSeconds: TimeInterval = 0

    public var meanDecodeSeconds: TimeInterval {
        decodes > 0 ? totalDecodeSeconds / Double(decodes) : 0
    }
}

/// Decides where a growing audio segment can be cut so that everything
/// before the cut becomes permanent text.
///
/// The model decodes a fixed window, so the open segment can't grow forever.
/// A cut is only safe between words, and only where the model has heard
/// enough audio *after* the cut for those words to have settled — the last
/// couple of seconds of any decode are the part most likely to change.
public struct LiveCommitPolicy: Sendable {
    /// Segments shorter than this are never cut (seconds).
    public var softLimit: Double = 8.0
    /// At this length a cut is forced at the best available gap (seconds).
    public var hardLimit: Double = 12.5
    /// The model's window; a segment must never reach it (seconds).
    public var windowLimit: Double = 14.5
    /// Words this close to the live edge are not settled (seconds).
    public var tailGuard: Double = 2.0
    /// Never cut this close to the segment start (seconds).
    public var headGuard: Double = 2.5
    /// Below the hard limit, only cut at a pause at least this "good".
    public var minimumScore: Double = 0.3
    /// How much a sentence end is worth, in seconds of pause.
    public var sentenceBonus: Double = 0.5

    public init() {}

    public struct Cut: Sendable, Equatable {
        /// Words `0..<wordCount` are committed.
        public let wordCount: Int
        /// Timeline position where the next segment begins.
        public let time: Double
    }

    /// - Parameters:
    ///   - words: the latest decode of the open segment, on the recording timeline
    ///   - segmentStart: timeline position of the segment's first sample
    ///   - segmentEnd: timeline position of its last sample
    public func cut(words: [LiveWord], segmentStart: Double, segmentEnd: Double) -> Cut? {
        let length = segmentEnd - segmentStart
        guard length > softLimit, words.count > 1 else { return nil }

        var best: (index: Int, score: Double)?
        for index in 0..<(words.count - 1) {
            let gapStart = words[index].end
            let gapEnd = words[index + 1].start
            guard gapStart >= segmentStart + headGuard, gapEnd <= segmentEnd - tailGuard else { continue }
            let endsSentence = words[index].text.last.map { ".!?…".contains($0) } ?? false
            let score = max(gapEnd - gapStart, 0) + (endsSentence ? sentenceBonus : 0)
            // Ties go to the later gap: it commits more and keeps the segment short
            if best == nil || score >= best!.score {
                best = (index, score)
            }
        }

        guard let best, best.score >= minimumScore || length > hardLimit else { return nil }
        let time = (words[best.index].end + words[best.index + 1].start) / 2
        return Cut(wordCount: best.index + 1, time: min(max(time, segmentStart), segmentEnd))
    }
}

/// Live transcription for a Parakeet-family model.
///
/// These models are not streaming models: they decode a whole (≤ 15 s) window
/// at once. But one window decodes in a fraction of a second on the Neural
/// Engine, so the session simply re-decodes the audio since the last commit
/// several times per second. Text for that open segment is *volatile* — it
/// sharpens as more audio arrives — and becomes *confirmed* once the segment
/// is cut at a pause (`LiveCommitPolicy`) or the speaker stops.
///
/// The result is a preview. When recording ends, the app transcribes the
/// saved file in one pass, which sees every window with full context on both
/// sides and yields the timestamps the transcript views need.
public actor LiveTranscriptionSession {
    private static let sampleRate = 16_000.0
    /// The model rejects less than a second of audio.
    private static let minimumSamples = 16_000
    /// RMS below which audio is never treated as speech (about -56 dBFS).
    private static let voiceFloor: Float = 0.0015
    /// RMS below which audio is digital silence (about -66 dBFS).
    private static let silenceFloor: Float = 0.0005

    private let manager: AsrManager
    private let language: Language?
    private let policy: LiveCommitPolicy
    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "Live")

    private let input: AsyncStream<[Float]>
    private let inputContinuation: AsyncStream<[Float]>.Continuation
    private let updatesContinuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    private var runner: Task<Void, Never>?

    /// Transcript updates, in order. Finishes when the session finishes or is cancelled.
    public nonisolated let updates: AsyncStream<LiveTranscriptUpdate>

    // Open segment: samples not yet committed, starting at `segmentStartSample`
    private var segment: [Float] = []
    private var segmentStartSample = 0
    private var totalSamples = 0

    private var confirmedText = ""
    private var volatileWords: [LiveWord] = []
    private var lastUpdate: LiveTranscriptUpdate?
    public private(set) var stats = LiveTranscriptionStats()

    // Pacing and voice activity
    private var samplesAtLastDecode = 0
    private var lastDecodeFinished = Date.distantPast
    private var lastDecodeDuration: TimeInterval = 0
    private var voiceSinceLastDecode = false
    private var loudestSinceLastDecode: Float = 0
    private var silentRunSamples = 0
    private var noiseFloor: Float = 0.002

    init(manager: AsrManager, language: Language?, policy: LiveCommitPolicy = LiveCommitPolicy()) {
        self.manager = manager
        self.language = language
        self.policy = policy

        // Audio arrives from a capture thread faster than it is consumed
        // during a decode; an unbounded buffer keeps every sample in order.
        let (input, inputContinuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.input = input
        self.inputContinuation = inputContinuation

        let (updates, updatesContinuation) = AsyncStream<LiveTranscriptUpdate>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.updates = updates
        self.updatesContinuation = updatesContinuation
    }

    /// Feeds 16 kHz mono samples. Safe to call from any thread; never blocks.
    public nonisolated func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        inputContinuation.yield(samples)
    }

    /// Starts consuming audio. Call once, before or after the first `append`.
    public func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            await self?.run()
        }
    }

    /// Ends the session: decodes what is left and returns the full text.
    public func finish() async -> String {
        inputContinuation.finish()
        await runner?.value
        runner = nil
        updatesContinuation.finish()
        return confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops immediately, discarding audio that has not been decoded.
    public func cancel() async {
        runner?.cancel()
        inputContinuation.finish()
        await runner?.value
        runner = nil
        updatesContinuation.finish()
    }

    // MARK: - Run loop

    private func run() async {
        for await chunk in input {
            if Task.isCancelled { return }
            ingest(chunk)
            if shouldDecode() {
                await decodeOpenSegment(final: false)
            }
        }
        guard !Task.isCancelled else { return }
        await decodeOpenSegment(final: true)
    }

    private func ingest(_ chunk: [Float]) {
        segment.append(contentsOf: chunk)
        totalSamples += chunk.count

        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = (sum / Float(chunk.count)).squareRoot()

        // Track the room's noise floor: fall quickly to quieter levels, rise slowly
        noiseFloor = rms < noiseFloor ? rms * 0.5 + noiseFloor * 0.5 : noiseFloor * 0.999 + rms * 0.001
        loudestSinceLastDecode = max(loudestSinceLastDecode, rms)
        let isVoice = rms > max(noiseFloor * 2.5, Self.voiceFloor)
        if isVoice {
            voiceSinceLastDecode = true
            silentRunSamples = 0
        } else {
            silentRunSamples += chunk.count
        }
    }

    private func shouldDecode() -> Bool {
        guard segment.count >= Self.minimumSamples else { return false }
        let newSamples = totalSamples - samplesAtLastDecode
        guard newSamples > 0 else { return false }

        let segmentSeconds = Double(segment.count) / Self.sampleRate
        if segmentSeconds >= policy.windowLimit { return true }

        // Leave the Neural Engine idle at least twice as long as it works,
        // so slower Macs degrade to fewer updates instead of falling behind.
        let pacing = max(0.3, lastDecodeDuration * 2.5)
        guard Date().timeIntervalSince(lastDecodeFinished) >= pacing else { return false }

        let newSeconds = Double(newSamples) / Self.sampleRate
        if voiceSinceLastDecode {
            return newSeconds >= 0.25
        }
        // Silence: one last decode once the speaker has paused, to settle and
        // commit what was said, then nothing until speech resumes.
        let pausedFor = Double(silentRunSamples) / Self.sampleRate
        if !volatileWords.isEmpty && pausedFor >= 0.9 { return true }
        // Safety net for very quiet inputs the voice detector misses: as long
        // as the signal isn't digital silence, still decode now and then.
        return newSeconds >= 4 && loudestSinceLastDecode > Self.silenceFloor
    }

    private func decodeOpenSegment(final: Bool) async {
        let segmentSeconds = Double(segment.count) / Self.sampleRate
        let segmentStart = Double(segmentStartSample) / Self.sampleRate
        let segmentEnd = segmentStart + segmentSeconds
        let hadSignal = voiceSinceLastDecode || loudestSinceLastDecode > Self.silenceFloor
        let pausedFor = Double(silentRunSamples) / Self.sampleRate

        samplesAtLastDecode = totalSamples
        voiceSinceLastDecode = false
        loudestSinceLastDecode = 0

        // Nothing but silence since the last commit: drop it instead of
        // decoding (keep a little lead-in so the next word isn't clipped).
        if !hadSignal && volatileWords.isEmpty {
            if !final { trimSilentSegment(keeping: 0.5) }
            return
        }

        var words = volatileWords
        if segment.count >= Self.minimumSamples {
            do {
                let started = Date()
                var decoderState = TdtDecoderState.make()
                let result = try await manager.transcribe(segment, decoderState: &decoderState, language: language)
                lastDecodeDuration = Date().timeIntervalSince(started)
                lastDecodeFinished = Date()
                stats.decodes += 1
                stats.totalDecodeSeconds += lastDecodeDuration
                stats.slowestDecodeSeconds = max(stats.slowestDecodeSeconds, lastDecodeDuration)
                // Pauses stay visible to the commit policy (see ParakeetWords)
                words = ParakeetWords.group(ParakeetWords.tokens(from: result.tokenTimings ?? [])).map {
                    LiveWord(text: $0.word, start: $0.start + segmentStart, end: $0.end + segmentStart)
                }
            } catch {
                // Keep the previous hypothesis; the next decode retries
                lastDecodeFinished = Date()
                logger.error("Live decode failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if Task.isCancelled { return }

        let utteranceEnded = pausedFor >= 0.9
        if words.isEmpty && !final {
            // Signal but no speech (noise, music): don't let it pile up
            volatileWords = []
            trimSilentSegment(keeping: 0.5)
        } else if final || utteranceEnded {
            // The speaker stopped: everything decoded so far is settled
            commit(words, paragraphBreak: !final && pausedFor >= 2.0)
            volatileWords = []
            resetSegment(toSample: totalSamples, keeping: final ? 0 : 0.3)
        } else if let cut = policy.cut(words: words, segmentStart: segmentStart, segmentEnd: segmentEnd) {
            commit(Array(words[..<cut.wordCount]), paragraphBreak: false)
            volatileWords = Array(words[cut.wordCount...])
            resetSegment(toSample: Int(cut.time * Self.sampleRate), keeping: 0)
        } else if segmentSeconds >= policy.windowLimit {
            // No usable gap in a full window (continuous speech without a
            // single pause, or no words at all): commit it whole rather than
            // let the segment outgrow the model.
            commit(words, paragraphBreak: false)
            volatileWords = []
            resetSegment(toSample: totalSamples, keeping: 0)
        } else {
            volatileWords = words
        }
        publish()
    }

    // MARK: - State changes

    private func commit(_ words: [LiveWord], paragraphBreak: Bool) {
        let text = words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }
        if confirmedText.isEmpty {
            confirmedText = text
        } else if confirmedText.hasSuffix("\n") {
            confirmedText += text
        } else {
            confirmedText += " " + text
        }
        if paragraphBreak {
            confirmedText += "\n\n"
        }
    }

    /// Moves the segment start to `sample` (absolute), optionally keeping
    /// `keeping` seconds before it as lead-in.
    private func resetSegment(toSample sample: Int, keeping: Double) {
        let target = max(segmentStartSample, min(sample - Int(keeping * Self.sampleRate), totalSamples))
        let drop = target - segmentStartSample
        guard drop > 0 else { return }
        segment.removeFirst(min(drop, segment.count))
        segmentStartSample = target
    }

    private func trimSilentSegment(keeping: Double) {
        resetSegment(toSample: totalSamples, keeping: keeping)
    }

    private func publish() {
        let update = LiveTranscriptUpdate(
            confirmed: confirmedText,
            volatile: volatileWords.map(\.text).joined(separator: " "),
            audioSeconds: Double(totalSamples) / Self.sampleRate
        )
        // Only text changes are worth a UI update
        if let lastUpdate, lastUpdate.confirmed == update.confirmed, lastUpdate.volatile == update.volatile {
            return
        }
        lastUpdate = update
        updatesContinuation.yield(update)
    }
}
