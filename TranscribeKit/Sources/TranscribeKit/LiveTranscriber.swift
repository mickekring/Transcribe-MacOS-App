import Foundation
import AVFoundation
import FluidAudio
import os

/// Live (while-recording) transcription with Klang Pianissimo.
///
/// About once a second the not-yet-committed tail of the audio (at most
/// ~12 s, one model window) is re-transcribed and shown as `volatileText`.
/// Words are committed to `confirmedText` once at least 2 s of audio follow
/// them, cutting preferably at a pause or punctuation, so committed text
/// never changes. Pianissimo runs far faster than real time, so each pass
/// takes a fraction of the interval.
///
/// Live text is a preview — the recording is still transcribed in full
/// afterwards, with speaker identification.
///
/// Audio threads call `append(_:)`; buffers are queued in order and consumed
/// by a single task.
@MainActor
public final class LiveTranscriber: ObservableObject {
    public enum State: Equatable {
        case idle
        case loading
        case running
        case finished
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var confirmedText = ""
    @Published public private(set) var volatileText = ""

    /// Confirmed + volatile text, as shown to the user.
    public var displayText: String {
        [confirmedText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isActive: Bool { state == .loading || state == .running }

    /// Live transcription needs the Pianissimo model on disk.
    public static var isModelAvailable: Bool {
        ModelManager.shared.isModelDownloaded(PianissimoService.modelId)
    }

    // Tuning (seconds)
    private static let sampleRate = 16_000
    private static let updateInterval = 1.0
    /// Commit once the open tail is this long...
    private static let commitAfter = 7.0
    /// ...keeping at least this much audio after the last committed word
    private static let rightContext = 2.0
    /// Audio before the commit point fed again for acoustic context
    private static let leftContext = 1.5
    /// Tails longer than this without any words (silence, music) are dropped
    private static let maxSilentTail = 10.0
    private static let minimumAudio = 1.0

    private let logger = Logger(subsystem: "com.mickekring.transcribe", category: "LiveTranscriber")

    private var task: Task<Void, Never>?
    private let bufferQueue = BufferQueue()
    private let converter = AudioConverter()

    /// 16 kHz mono samples from `bufferStart` (absolute index) onwards
    private var samples: [Float] = []
    private var bufferStart = 0
    /// Absolute sample index up to which text is committed
    private var commitPoint = 0
    private var committedWords: [String] = []

    public init() {}

    /// Thread-safe; call from any audio callback. Buffers arriving before
    /// the model has loaded are queued and transcribed once it is ready.
    public nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        bufferQueue.yield(buffer)
    }

    /// Starts a new session. Audio can be appended immediately.
    public func start() {
        guard !isActive else { return }
        resetSession()
        state = .loading
        let stream = bufferQueue.open()

        task = Task { @MainActor in
            do {
                let models = try await PianissimoService.shared.loadedModels()
                // A dedicated manager: live decoding never contends with
                // the shared file-transcription manager's state.
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                if self.state == .loading { self.state = .running }

                var lastPass = Date.distantPast
                for await buffer in stream {
                    try Task.checkCancellation()
                    self.samples.append(contentsOf: try self.converter.resampleBuffer(buffer))
                    if Date().timeIntervalSince(lastPass) >= Self.updateInterval {
                        lastPass = Date()
                        try await self.pass(manager: manager, final: false)
                    }
                }
                try Task.checkCancellation()
                try await self.pass(manager: manager, final: true)
                self.state = .finished
            } catch is CancellationError {
                return
            } catch {
                self.logger.error("Live transcription failed: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error.localizedDescription)
                self.bufferQueue.close()
            }
        }
    }

    /// Stops accepting audio and transcribes what remains; returns when the
    /// final text is published.
    public func stop() async {
        guard isActive else { return }
        bufferQueue.close()
        await task?.value
        task = nil
    }

    /// Discards the session without waiting for a final result.
    public func cancel() {
        bufferQueue.close()
        task?.cancel()
        task = nil
        resetSession()
        state = .idle
    }

    private func resetSession() {
        samples = []
        bufferStart = 0
        commitPoint = 0
        committedWords = []
        confirmedText = ""
        volatileText = ""
    }

    // MARK: - Decoding

    /// Transcribes the open tail, commits stable words, publishes text.
    private func pass(manager: AsrManager, final: Bool) async throws {
        let rate = Double(Self.sampleRate)
        let end = bufferStart + samples.count
        let decodeStart = max(bufferStart, commitPoint - Int(Self.leftContext * rate))
        let tailSeconds = Double(end - commitPoint) / rate

        guard Double(end - decodeStart) / rate >= Self.minimumAudio else {
            if final { volatileText = "" }
            return
        }

        let window = Array(samples[(decodeStart - bufferStart)..<(end - bufferStart)])
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(window, decoderState: &decoderState, language: .swedish)

        // Absolute times; keep only words after the commit point
        let offset = Double(decodeStart) / rate
        let commitTime = Double(commitPoint) / rate
        let words = buildWordTimings(from: result.tokenTimings ?? [])
            .map { WordTiming(word: $0.word, startTime: $0.startTime + offset, endTime: $0.endTime + offset) }
            .filter { ($0.startTime + $0.endTime) / 2 >= commitTime }
        let endTime = Double(end) / rate

        if final {
            committedWords += words.map(\.word)
            commitPoint = end
        } else if let cut = Self.commitIndex(words: words, tailSeconds: tailSeconds, endTime: endTime) {
            committedWords += words[...cut].map(\.word)
            let nextStart = cut + 1 < words.count ? words[cut + 1].startTime : endTime
            let cutTime = min(words[cut].endTime + 0.15, (words[cut].endTime + nextStart) / 2)
            commitPoint = Int(cutTime * rate)
            publish(volatile: Array(words[(cut + 1)...]))
            trimBuffer()
            return
        } else if words.isEmpty && tailSeconds > Self.maxSilentTail {
            commitPoint = end - Int(Self.rightContext * rate)
            trimBuffer()
        }
        publish(volatile: final ? [] : words)
    }

    /// The last word that can be committed: at least `rightContext` before
    /// the end, preferring a sentence end, a comma or a pause.
    private static func commitIndex(words: [WordTiming], tailSeconds: Double, endTime: Double) -> Int? {
        guard tailSeconds >= commitAfter else { return nil }
        let eligible = words.indices.filter { words[$0].endTime <= endTime - rightContext }
        guard let last = eligible.last else { return nil }
        let preferred = eligible.last { i in
            let gap = (i + 1 < words.count ? words[i + 1].startTime : endTime) - words[i].endTime
            let punctuated = words[i].word.last.map { ".?!,".contains($0) } ?? false
            return punctuated || gap >= 0.3
        }
        // Don't cut so early that the tail barely shrinks
        if let preferred, words[preferred].endTime - (words.first?.startTime ?? 0) >= 2.0 {
            return preferred
        }
        return last
    }

    private func publish(volatile: [WordTiming]) {
        confirmedText = committedWords.joined(separator: " ")
        volatileText = volatile.map(\.word).joined(separator: " ")
    }

    /// Drops audio no longer needed for left context.
    private func trimBuffer() {
        let keepFrom = commitPoint - Int(Self.leftContext * Double(Self.sampleRate))
        let drop = keepFrom - bufferStart
        guard drop > 0, drop <= samples.count else { return }
        samples.removeFirst(drop)
        bufferStart += drop
    }
}

/// Ordered, thread-safe hand-off of audio buffers from capture callbacks.
/// Buffers are copied, since capture APIs may reuse theirs after the callback.
private final class BufferQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    func open() -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        lock.withLock {
            self.continuation?.finish()
            self.continuation = continuation
        }
        return stream
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = lock.withLock({ self.continuation }),
              let copy = Self.copy(buffer) else { return }
        continuation.yield(copy)
    }

    func close() {
        let continuation = lock.withLock { () -> AsyncStream<AVAudioPCMBuffer>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            memcpy(dstData, srcData, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }
}
