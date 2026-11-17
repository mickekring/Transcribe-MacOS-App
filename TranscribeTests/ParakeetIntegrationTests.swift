import AVFoundation
import Foundation
import Testing
import os
@testable import TranscribeKit

/// End-to-end checks of the Parakeet-family engine against the real models.
///
/// They download several hundred MB on first run and need the Neural Engine,
/// so they are opt-in: set `RUN_MODEL_TESTS=1` in the test runner environment.
/// Speech is synthesised on the spot with the system voices, so no audio is
/// checked into the repository.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1", "set RUN_MODEL_TESTS=1 to run"),
    .serialized,
    .timeLimit(.minutes(20))
)
@MainActor
struct ParakeetIntegrationTests {
    private static let log = Logger(subsystem: "com.mickekring.transcribe.tests", category: "integration")

    static let swedish = """
    Välkommen till dagens möte. Vi ska gå igenom tre punkter på dagordningen. \
    Först tittar vi på budgeten för nästa kvartal, och sedan diskuterar vi rekryteringen av två nya utvecklare till teamet i Göteborg. \
    Avslutningsvis behöver vi bestämma ett datum för sommarfesten. \
    Jag föreslår att vi börjar med budgeten, eftersom den påverkar allt annat. \
    Förra året gick vi ungefär sju procent över, främst på grund av ökade kostnader för molntjänster. \
    Finns det några frågor innan vi sätter igång?
    """

    static let english = """
    Good morning everyone, and thank you for joining. \
    Today we are going to review the quarterly results and talk about the roadmap for next year. \
    Revenue grew strongly, mostly because of the new subscription plan. \
    After that, we will open the floor for questions.
    """

    @Test func pianissimoTranscribesSwedishSpeech() async throws {
        let fixture = try await SpeechFixture.make(text: Self.swedish, language: "sv-SE")
        defer { fixture.remove() }

        let started = Date()
        let result = try await transcribe(fixture.url, modelId: "pianissimo_sv-coreml", language: "sv")
        let elapsed = Date().timeIntervalSince(started)
        let wer = Self.wordErrorRate(reference: Self.swedish, hypothesis: result.final.text)
        Self.log.notice("PIANISSIMO batch: audio \(fixture.duration, format: .fixed(precision: 1))s in \(elapsed, format: .fixed(precision: 2))s (incl. load), WER \(wer, format: .fixed(precision: 3)), previews \(result.previews), segments \(result.final.segments.count)")
        Self.log.notice("PIANISSIMO text: \(result.final.text, privacy: .public)")

        #expect(wer < 0.2, "word error rate \(wer) on synthesised Swedish")
        for word in ["budgeten", "göteborg", "sommarfesten", "molntjänster"] {
            #expect(result.final.text.lowercased().contains(word), "missing \(word)")
        }

        // Timed segments: ordered, inside the audio, and carrying their words
        let segments = result.final.segments
        #expect(segments.count >= 4)
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(segments.allSatisfy { $0.start >= 0 && $0.end <= fixture.duration + 0.5 && $0.end >= $0.start })
        let words = segments.flatMap { $0.words ?? [] }
        #expect(words.count > 60)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start + 0.001 })
        #expect(words.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 })
        #expect(segments.map(\.text).joined(separator: " ") == result.final.text)
        // Longer than one 15 s window, so the preview must have streamed
        #expect(fixture.duration > 20)
        #expect(result.previews >= 1)
    }

    @Test func liveSessionFollowsSwedishSpeechWithoutRewritingConfirmedText() async throws {
        let fixture = try await SpeechFixture.make(text: Self.swedish, language: "sv-SE")
        defer { fixture.remove() }

        let session = try await ParakeetService.shared.makeLiveSession(modelId: "pianissimo_sv-coreml", language: "sv")
        await session.start()

        let collector = Task { () -> [LiveTranscriptUpdate] in
            var updates: [LiveTranscriptUpdate] = []
            for await update in session.updates { updates.append(update) }
            return updates
        }

        // Feed in real time, 100 ms at a time, like the microphone tap does
        let chunk = 1_600
        var index = 0
        var firstTextAt: Double?
        let feedStart = Date()
        while index < fixture.samples.count {
            let end = min(index + chunk, fixture.samples.count)
            session.append(Array(fixture.samples[index..<end]))
            index = end
            try await Task.sleep(for: .milliseconds(100))
            _ = firstTextAt
        }
        let finalText = await session.finish()
        let updates = await collector.value
        let stats = await session.stats
        let feedSeconds = Date().timeIntervalSince(feedStart)
        if let first = updates.first(where: { !$0.isEmpty }) { firstTextAt = first.audioSeconds }

        let wer = Self.wordErrorRate(reference: Self.swedish, hypothesis: finalText)
        Self.log.notice("LIVE: \(updates.count) updates over \(feedSeconds, format: .fixed(precision: 1))s, first text at \(firstTextAt ?? -1, format: .fixed(precision: 1))s, \(stats.decodes) decodes, mean \(stats.meanDecodeSeconds * 1000, format: .fixed(precision: 0))ms, slowest \(stats.slowestDecodeSeconds * 1000, format: .fixed(precision: 0))ms, WER \(wer, format: .fixed(precision: 3))")
        Self.log.notice("LIVE text: \(finalText, privacy: .public)")

        // Words appear while the speaker is still in the first sentence
        #expect((firstTextAt ?? .infinity) < 4.0)
        // Several updates per second of speech on average would be ~100+; a
        // slow machine still gives one every couple of seconds
        #expect(updates.count >= Int(fixture.duration / 2))
        // The contract the UI relies on: confirmed text only ever grows
        var previous = ""
        for update in updates {
            #expect(update.confirmed.hasPrefix(previous), "confirmed text was rewritten")
            previous = update.confirmed
        }
        #expect(finalText.hasPrefix(previous.trimmingCharacters(in: .whitespacesAndNewlines)) || previous.isEmpty)
        // The Neural Engine must keep up with real time with room to spare
        #expect(stats.meanDecodeSeconds < 0.5)
        #expect(wer < 0.3, "live word error rate \(wer)")
    }

    @Test func parakeetV3TranscribesEnglishSpeech() async throws {
        let fixture = try await SpeechFixture.make(text: Self.english, language: "en-US")
        defer { fixture.remove() }

        let result = try await transcribe(fixture.url, modelId: "parakeet_tdt-v3-coreml", language: "en")
        let wer = Self.wordErrorRate(reference: Self.english, hypothesis: result.final.text)
        Self.log.notice("PARAKEET v3 text (WER \(wer, format: .fixed(precision: 3))): \(result.final.text, privacy: .public)")
        #expect(wer < 0.2)
        #expect(result.final.text.lowercased().contains("quarterly"))
        #expect(!result.final.segments.isEmpty)
    }

    // MARK: Speakers
    //
    // Speaker identification does not depend on the engine: diarization runs
    // on the audio file, and its turns are matched to the transcript's word
    // timings. The first test checks the Parakeet half of that (words land on
    // the right turn); the second runs the whole chain on two distinct voices.

    static let alva = "com.apple.voice.compact.sv-SE.Alva"
    // The only other Swedish voice is a Siri voice, which the sandboxed test
    // host can't use; the Norwegian voice reads Swedish well enough
    static let nora = "com.apple.voice.compact.nb-NO.Nora"

    @Test func pianissimoWordsLandOnTheRightSpeakerTurn() async throws {
        // Each line with words from its start and its end, as Pianissimo spells them
        let script: [(voice: String, text: String, first: String, last: String)] = [
            (Self.alva, "Välkommen allihop. Jag tänkte att vi börjar med budgeten för nästa kvartal, eftersom den påverkar allt annat.", "Välkommen", "annat"),
            (Self.nora, "Det låter bra. Jag har gått igenom siffrorna i helgen och vi ligger tyvärr en bit över plan.", "låter", "plan"),
            (Self.alva, "Hur mycket över ligger vi, och vad beror det framför allt på?", "Hur mycket", "framför allt"),
            (Self.nora, "Ungefär sju procent. Det mesta kommer från molntjänster och några nya licenser som vi inte hade räknat med.", "Ungefär", "licenser"),
            (Self.alva, "Då behöver vi prata med leverantören innan sommaren. Kan du ta det?", "leverantören", "ta det"),
            (Self.nora, "Absolut, jag bokar ett möte med dem redan nästa vecka och återkommer till gruppen.", "Absolut", "gruppen"),
        ]
        let dialogue = try await SpeechFixture.dialogue(script.map { ($0.voice, $0.text) })
        defer { dialogue.fixture.remove() }

        let result = try await transcribe(dialogue.fixture.url, modelId: "pianissimo_sv-coreml", language: "sv")
        #expect(result.final.segments.flatMap { $0.words ?? [] }.count > 60, "the word timings speaker matching needs")

        // The turns a perfect diarizer would give
        let turns = dialogue.lines.map { SpeakerTurn(speakerId: $0.voice == Self.alva ? 0 : 1, start: $0.start, end: $0.end) }
        let formatted = SpeakerTranscriptFormatter.format(
            segments: result.final.segments, turns: turns,
            speakerName: { $0 == 0 ? "ALVA" : "NORA" }, unknownLabel: "?"
        )
        Self.log.notice("SPEAKERS pianissimo: \(formatted.replacingOccurrences(of: "\n", with: " | "), privacy: .public)")

        // One block per line, alternating, each holding its own line's words
        let blocks = formatted.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        try #require(blocks.count == script.count, "\(blocks.count) speaker blocks")
        for (block, line) in zip(blocks, script) {
            #expect(block.contains(line.voice == Self.alva ? "ALVA" : "NORA"), "\(block)")
            #expect(block.contains(line.first) && block.contains(line.last), "\(block)")
        }

        // The real diarizer on the same audio: whatever it makes of two similar
        // synthetic voices, it must hear where one stops and the other starts
        let auto = try await DiarizationService.shared.diarize(fileURL: dialogue.fixture.url)
        Self.log.notice("SPEAKERS diarizer on two similar voices: \(Set(auto.map(\.speakerId)).count) speakers, turns \(auto.map { "\($0.speakerId)@\(String(format: "%.1f", $0.start))" }.joined(separator: " "), privacy: .public)")
        for line in dialogue.lines {
            #expect(auto.contains { abs($0.start - line.start) < 0.5 }, "no turn starts near \(line.start) s")
        }
    }

    @Test func diarizationNeverMixesTwoVoicesInAParakeetTranscript() async throws {
        let samantha = "com.apple.voice.compact.en-US.Samantha"
        let daniel = "com.apple.voice.compact.en-GB.Daniel"
        let dialogue = try await SpeechFixture.dialogue([
            (samantha, "Good morning. I thought we could start with the budget for next quarter, since it affects everything else."),
            (daniel, "Sounds good. I went through the numbers over the weekend, and we are a little over plan."),
            (samantha, "How far over are we, and what is driving it?"),
            (daniel, "About seven percent. Most of it comes from cloud services and a few new licences we had not planned for."),
            (samantha, "Then we need to talk to the supplier before the summer. Can you take that?"),
            (daniel, "Absolutely. I will book a meeting with them next week and report back to the group."),
        ])
        defer { dialogue.fixture.remove() }

        let result = try await transcribe(dialogue.fixture.url, modelId: "parakeet_tdt-v3-coreml", language: "en")
        let segments = result.final.segments
        let words = segments.flatMap { $0.words ?? [] }
        // Who really said each word: the line it falls in (Parakeet starts
        // words a few frames early, hence the margin)
        let voices: [String?] = words.map { word in
            let middle = (word.start + word.end) / 2
            return dialogue.lines.first { middle >= $0.start - 0.4 && middle <= $0.end + 0.4 }?.voice
        }

        // One person may get two labels (the speaker model's call, the same
        // for every engine), but a label must never hold two people: at every
        // speaker change the transcript splits between the right words
        let turns = try await DiarizationService.shared.diarize(fileURL: dialogue.fixture.url)
        let ids = try speakerPerWord(segments: segments, turns: turns, wordCount: words.count)
        for id in Set(ids.compactMap { $0 }) {
            let heard = zip(ids, voices).filter { $0.0 == id }.compactMap { $0.1 }
            let majority = Dictionary(grouping: heard, by: { $0 }).values.map(\.count).max() ?? 0
            #expect(Double(majority) / Double(max(heard.count, 1)) > 0.95, "speaker \(id) holds both voices")
        }
        // And the two voices are told apart
        func label(of voice: String) -> Int? {
            Dictionary(grouping: zip(ids, voices).filter { $0.1 == voice }.compactMap { $0.0 }, by: { $0 })
                .max { $0.value.count < $1.value.count }?.key
        }
        #expect(label(of: samantha) != nil && label(of: samantha) != label(of: daniel))

        let formatted = SpeakerTranscriptFormatter.format(
            segments: segments, turns: turns, speakerName: { "S\($0)" }, unknownLabel: "?"
        )
        Self.log.notice("SPEAKERS parakeet v3: \(Set(turns.map(\.speakerId)).count) speakers: \(formatted.replacingOccurrences(of: "\n", with: " | "), privacy: .public)")
    }

    /// The speaker the transcript gives each word, read back from the
    /// formatter's own output so its turn cleaning is part of what's tested.
    private func speakerPerWord(segments: [TranscriptionSegmentData], turns: [SpeakerTurn], wordCount: Int) throws -> [Int?] {
        let formatted = SpeakerTranscriptFormatter.format(
            segments: segments, turns: turns, speakerName: { "S\($0)" }, unknownLabel: "S?"
        )
        var ids: [Int?] = []
        for block in formatted.components(separatedBy: "\n\n") {
            let parts = block.split(separator: "\n", maxSplits: 1)
            guard parts.count == 2, let label = parts[0].split(separator: " ").last else { continue }
            let id = Int(label.dropFirst().dropLast())
            ids += Array(repeating: id, count: parts[1].split(separator: " ").count)
        }
        try #require(ids.count == wordCount, "\(ids.count) labelled words for \(wordCount)")
        return ids
    }

    @Test func silenceGivesAnEmptyTranscriptNotAnError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SpeechFixture.writeWAV(samples: [Float](repeating: 0, count: 16_000 * 6), to: url)

        let result = try await transcribe(url, modelId: "pianissimo_sv-coreml", language: "sv")
        #expect(result.final.text.isEmpty)
        #expect(result.final.segments.isEmpty)

        // Half a second is below the model's minimum input
        try SpeechFixture.writeWAV(samples: [Float](repeating: 0, count: 8_000), to: url)
        let tiny = try await transcribe(url, modelId: "pianissimo_sv-coreml", language: "sv")
        #expect(tiny.final.text.isEmpty)
    }

    // MARK: - Helpers

    private func transcribe(_ url: URL, modelId: String, language: String) async throws -> (final: TranscriptionUpdate, previews: Int) {
        var final: TranscriptionUpdate?
        var previews = 0
        for try await update in ParakeetService.shared.transcribe(fileURL: url, modelId: modelId, language: language) {
            if update.isComplete {
                final = update
            } else if update.progress >= 0.15 {
                previews += 1
            }
        }
        return (try #require(final), previews)
    }

    /// Word error rate on lowercased text with punctuation removed.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        func normalise(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let ref = normalise(reference)
        let hyp = normalise(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var previous = Array(0...hyp.count)
        for i in 1...ref.count {
            var current = [i] + [Int](repeating: 0, count: hyp.count)
            if !hyp.isEmpty {
                for j in 1...hyp.count {
                    let substitution = previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                    current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
                }
            }
            previous = current
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }
}

/// Speech synthesised with a system voice, as 16 kHz mono samples and a WAV file.
struct SpeechFixture {
    let url: URL
    let samples: [Float]
    var duration: Double { Double(samples.count) / 16_000 }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    struct MissingVoice: Error, CustomStringConvertible {
        let language: String
        var description: String { "No system voice installed for \(language)" }
    }

    @MainActor
    static func make(text: String, language: String) async throws -> SpeechFixture {
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            throw MissingVoice(language: language)
        }
        let samples = try await synthesize(text, voice: voice)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).wav")
        try writeWAV(samples: samples, to: url)
        return SpeechFixture(url: url, samples: samples)
    }

    /// Lines spoken in turn by the given voices (by identifier), with a short
    /// pause between them, and where each line sits in the audio.
    @MainActor
    static func dialogue(_ script: [(voice: String, text: String)]) async throws
        -> (fixture: SpeechFixture, lines: [(voice: String, start: Double, end: Double)]) {
        let pause = [Float](repeating: 0, count: 16_000 * 7 / 10)
        var samples: [Float] = []
        var lines: [(voice: String, start: Double, end: Double)] = []
        for (identifier, text) in script {
            guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
                throw MissingVoice(language: identifier)
            }
            let start = Double(samples.count) / 16_000
            samples += try await synthesize(text, voice: voice)
            lines.append((identifier, start, Double(samples.count) / 16_000))
            samples += pause
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dialogue-\(UUID().uuidString).wav")
        try writeWAV(samples: samples, to: url)
        return (SpeechFixture(url: url, samples: samples), lines)
    }

    @MainActor
    private static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice) async throws -> [Float] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        let synthesizer = AVSpeechSynthesizer()
        let collector = BufferCollector()
        synthesizer.delegate = collector
        let buffers: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            collector.onFinish(continuation)
            synthesizer.write(utterance) { buffer in
                // Empty buffers also arrive between sentences, so they can't
                // mark the end; the delegate does.
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
                collector.append(pcm)
            }
        }
        synthesizer.delegate = nil
        return try resample(buffers)
    }

    private static func resample(_ buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        guard let first = buffers.first,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: first.format, to: target) else { return [] }
        var samples: [Float] = []
        var queue = buffers[...]
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_000) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let next = queue.popFirst() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        return samples
    }

    static func writeWAV(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
    }
}

/// Gathers synthesiser buffers (delivered on an arbitrary queue) and resumes
/// once, when the synthesiser reports the utterance finished or cancelled.
private final class BufferCollector: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        buffers.append(buffer)
    }

    func onFinish(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    private func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result = buffers
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }
}
