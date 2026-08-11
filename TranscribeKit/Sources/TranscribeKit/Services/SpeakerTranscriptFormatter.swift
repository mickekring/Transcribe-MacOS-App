import Foundation

/// Renders transcription segments grouped into speaker turns:
/// each turn starts with "[MM:SS] Talare N:" followed by its text.
/// When word timings exist, assignment happens per word — short
/// interjections ("ja", "precis") land on the right speaker even when
/// Whisper packed them into another speaker's segment.
///
/// This is the tuned pipeline validated on the annotated benchmark clips;
/// both the macOS and iOS apps must format through it so they stay in sync.
public enum SpeakerTranscriptFormatter {

    /// - Parameters:
    ///   - speakerName: display name for a speaker id (user-assigned names
    ///     live in view state, so the caller supplies the mapping)
    ///   - unknownLabel: label used when no speaker can be assigned
    public static func format(
        segments: [TranscriptionSegmentData],
        turns: [SpeakerTurn],
        speakerName: (Int) -> String,
        unknownLabel: String
    ) -> String {
        let allWords = segments.flatMap { $0.words ?? [] }
        if !allWords.isEmpty && !turns.isEmpty {
            return formatWordLevel(words: allWords, turns: turns,
                                   speakerName: speakerName, unknownLabel: unknownLabel)
        }
        return formatSegmentLevel(segments, turns: turns,
                                  speakerName: speakerName, unknownLabel: unknownLabel)
    }

    private static func formatWordLevel(
        words: [WordTimestamp],
        turns: [SpeakerTurn],
        speakerName: (Int) -> String,
        unknownLabel: String
    ) -> String {
        // Diarization turn boundaries are ~±0.5s sloppy and leave micro-turn
        // debris at handovers; clean both before trusting them per word.
        let cleanedTurns = cleanTurns(turns, words: words)

        func speaker(for word: WordTimestamp) -> Int? {
            let mid = (word.start + word.end) / 2
            // Containing turn wins; otherwise nearest turn by midpoint distance
            if let containing = cleanedTurns.first(where: { mid >= $0.start && mid <= $0.end }) {
                return containing.speakerId
            }
            return cleanedTurns.min(by: { distance(mid, to: $0) < distance(mid, to: $1) })?.speakerId
        }

        var blocks: [String] = []
        var currentSpeaker: Int? = nil
        var currentWords: [String] = []
        var turnStart: Double = 0

        func flush() {
            guard !currentWords.isEmpty else { return }
            let label = currentSpeaker.map { speakerName($0) } ?? unknownLabel
            let text = currentWords.joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            blocks.append("[\(formatTime(turnStart))] \(label):\n" + text)
        }

        for word in words {
            let id = speaker(for: word) ?? currentSpeaker
            if id != currentSpeaker || currentWords.isEmpty {
                flush()
                currentWords = []
                currentSpeaker = id
                turnStart = word.start
            }
            currentWords.append(word.word.trimmingCharacters(in: .whitespaces))
        }
        flush()

        return blocks.joined(separator: "\n\n")
    }

    /// Cleans raw diarization turns for word-level assignment:
    /// 1. Drops micro-turns (<0.3s) — boundary-uncertainty debris, observed
    ///    as 20-50ms slivers at real handovers
    /// 2. Snaps each speaker change to the largest inter-word pause within
    ///    ±0.7s of the detected boundary — people change speakers in
    ///    silences, and word timings know where the silences are. Fixes the
    ///    "sentence-start lands on the previous speaker" class of errors.
    static func cleanTurns(_ turns: [SpeakerTurn], words: [WordTimestamp]) -> [SpeakerTurn] {
        // 1: drop debris, merge adjacent same-speaker turns
        var filtered: [SpeakerTurn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            if turn.end - turn.start < 0.3 { continue }
            if let last = filtered.last, last.speakerId == turn.speakerId {
                filtered[filtered.count - 1] = SpeakerTurn(speakerId: turn.speakerId, start: last.start, end: turn.end)
            } else {
                filtered.append(turn)
            }
        }
        guard filtered.count > 1, words.count > 1 else { return filtered }

        // Inter-word gaps: (time between two words, gap midpoint)
        let sortedWords = words.sorted(by: { $0.start < $1.start })
        var gaps: [(size: Double, at: Double)] = []
        for i in 1..<sortedWords.count {
            let gap = sortedWords[i].start - sortedWords[i - 1].end
            if gap > 0.05 {
                gaps.append((gap, (sortedWords[i - 1].end + sortedWords[i].start) / 2))
            }
        }

        // 2: snap each boundary to the largest nearby pause
        var snapped = filtered
        for i in 1..<snapped.count {
            let boundary = snapped[i].start
            let window = 0.7
            if let bestGap = gaps
                .filter({ abs($0.at - boundary) <= window })
                .max(by: { $0.size < $1.size }) {
                let newBoundary = bestGap.at
                snapped[i - 1] = SpeakerTurn(speakerId: snapped[i - 1].speakerId, start: snapped[i - 1].start, end: newBoundary)
                snapped[i] = SpeakerTurn(speakerId: snapped[i].speakerId, start: newBoundary, end: snapped[i].end)
            }
        }
        return snapped
    }

    private static func distance(_ time: Double, to turn: SpeakerTurn) -> Double {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    private static func formatSegmentLevel(
        _ segments: [TranscriptionSegmentData],
        turns: [SpeakerTurn],
        speakerName: (Int) -> String,
        unknownLabel: String
    ) -> String {
        var blocks: [String] = []
        var currentSpeaker: Int? = nil
        var currentLines: [String] = []
        var turnStart: Double = 0

        func flush() {
            guard !currentLines.isEmpty else { return }
            let label = currentSpeaker.map { speakerName($0) } ?? unknownLabel
            blocks.append("[\(formatTime(turnStart))] \(label):\n" + currentLines.joined(separator: " "))
        }

        for segment in segments {
            // Carry the previous speaker through segments with no overlap
            // (short interjections between detected turns).
            let speaker = dominantSpeaker(for: segment, in: turns) ?? currentSpeaker
            if speaker != currentSpeaker || currentLines.isEmpty {
                flush()
                currentLines = []
                currentSpeaker = speaker
                turnStart = segment.start
            }
            currentLines.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        flush()

        return blocks.joined(separator: "\n\n")
    }

    /// The speaker whose turns overlap this segment the most, or nil if none overlap.
    private static func dominantSpeaker(for segment: TranscriptionSegmentData, in turns: [SpeakerTurn]) -> Int? {
        var overlapBySpeaker: [Int: Double] = [:]
        for turn in turns {
            let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
            if overlap > 0 {
                overlapBySpeaker[turn.speakerId, default: 0] += overlap
            }
        }
        return overlapBySpeaker.max(by: { $0.value < $1.value })?.key
    }

    private static func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
