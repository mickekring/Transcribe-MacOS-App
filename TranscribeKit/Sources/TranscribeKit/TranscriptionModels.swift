import Foundation
import CoreAudio

public struct TranscriptionResult: Identifiable, Codable {
    public let id: UUID
    public let text: String
    public let segments: [TranscriptionSegment]
    public let language: String
    public let duration: TimeInterval
    public let timestamp: Date
    public let modelUsed: String
    
    public init(id: UUID = UUID(), text: String, segments: [TranscriptionSegment], language: String, duration: TimeInterval, timestamp: Date, modelUsed: String) {
        self.id = id
        self.text = text
        self.segments = segments
        self.language = language
        self.duration = duration
        self.timestamp = timestamp
        self.modelUsed = modelUsed
    }
    
    public var formattedText: String {
        segments.map { $0.text }.joined(separator: " ")
    }
}

#if os(macOS)
// CoreAudio HAL device IDs only exist on macOS; iOS uses AVAudioSession routing.
public struct AudioInputDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String

    public init(id: AudioDeviceID, name: String) {
        self.id = id
        self.name = name
    }
}
#endif

public struct TranscriptionSegment: Codable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let confidence: Float?
    public let speaker: String?
    /// Word-level timings (WhisperX align / WhisperKit wordTimestamps)
    public let words: [TranscriptionWord]?

    public init(id: Int, start: TimeInterval, end: TimeInterval, text: String,
         confidence: Float?, speaker: String?, words: [TranscriptionWord]? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.speaker = speaker
        self.words = words
    }
}

public struct TranscriptionWord: Codable {
    public let word: String
    public let start: TimeInterval
    public let end: TimeInterval
    /// Speaker label when server-side diarization assigned one per word
    public let speaker: String?
}

// MARK: - Text Processing Prompts

public struct TextProcessingPrompt: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var prompt: String
    public let createdAt: Date
    
    public init(id: UUID = UUID(), name: String, prompt: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.createdAt = createdAt
    }
}
// MARK: - Streaming segment data (UI-facing)

public struct TranscriptionSegmentData {
    public let start: Double
    public let end: Double
    public let text: String
    public let words: [WordTimestamp]?

    public init(start: Double, end: Double, text: String, words: [WordTimestamp]?) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

public struct WordTimestamp {
    public let word: String
    public let start: Double
    public let end: Double
    public let confidence: Float

    public init(word: String, start: Double, end: Double, confidence: Float) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}
