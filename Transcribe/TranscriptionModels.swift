import Foundation
import CoreAudio

struct TranscriptionResult: Identifiable, Codable {
    let id: UUID
    let text: String
    let segments: [TranscriptionSegment]
    let language: String
    let duration: TimeInterval
    let timestamp: Date
    let modelUsed: String
    
    init(id: UUID = UUID(), text: String, segments: [TranscriptionSegment], language: String, duration: TimeInterval, timestamp: Date, modelUsed: String) {
        self.id = id
        self.text = text
        self.segments = segments
        self.language = language
        self.duration = duration
        self.timestamp = timestamp
        self.modelUsed = modelUsed
    }
    
    var formattedText: String {
        segments.map { $0.text }.joined(separator: " ")
    }
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

struct TranscriptionSegment: Codable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let confidence: Float?
    let speaker: String?
    /// Word-level timings (WhisperX align / WhisperKit wordTimestamps)
    let words: [TranscriptionWord]?

    init(id: Int, start: TimeInterval, end: TimeInterval, text: String,
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

struct TranscriptionWord: Codable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    /// Speaker label when server-side diarization assigned one per word
    let speaker: String?
}

// MARK: - Text Processing Prompts

struct TextProcessingPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    let createdAt: Date
    
    init(id: UUID = UUID(), name: String, prompt: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.createdAt = createdAt
    }
}