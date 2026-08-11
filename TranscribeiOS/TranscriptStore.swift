import Foundation
import TranscribeKit

/// A finished transcription kept in the phone's library. Unlike the Mac app
/// (which treats everything as temporary), the phone keeps recordings and
/// transcripts in Documents so a meeting captured on the go isn't lost.
struct TranscriptRecord: Codable, Identifiable {
    var id: UUID
    var title: String
    var date: Date
    /// File name inside Documents/Recordings, nil if the audio was deleted
    var audioFileName: String?
    var duration: Double
    var modelId: String
    var text: String
    var segments: [TranscriptionSegmentData]?
    var turns: [SpeakerTurn]?
    var speakerNames: [Int: String]

    /// Speaker-labeled transcript via the shared tuned pipeline, honoring
    /// user-assigned names. Nil when diarization wasn't run.
    var speakerTranscript: String? {
        guard let segments, let turns, !turns.isEmpty else { return nil }
        return SpeakerTranscriptFormatter.format(
            segments: segments,
            turns: turns,
            speakerName: { speakerNames[$0] ?? String(format: localized("speaker_label"), $0 + 1) },
            unknownLabel: localized("speaker_unknown")
        )
    }

    var speakerIds: [Int] {
        guard let turns else { return [] }
        return Array(Set(turns.map(\.speakerId))).sorted()
    }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        let url = RecordingService.recordingsDirectory().appendingPathComponent(audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// JSON-file-per-record persistence in Documents/Transcripts.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var records: [TranscriptRecord] = []

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        load()
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(TranscriptRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    func add(_ record: TranscriptRecord) {
        records.insert(record, at: 0)
        records.sort { $0.date > $1.date }
        persist(record)
    }

    func update(_ record: TranscriptRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        }
        persist(record)
    }

    func delete(_ record: TranscriptRecord) {
        records.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: fileURL(for: record.id))
        if let audio = record.audioURL {
            try? FileManager.default.removeItem(at: audio)
        }
    }

    private func persist(_ record: TranscriptRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(record) {
            try? data.write(to: fileURL(for: record.id))
        }
    }

    private func fileURL(for id: UUID) -> URL {
        Self.directory.appendingPathComponent("\(id.uuidString).json")
    }
}
