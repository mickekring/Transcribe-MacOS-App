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