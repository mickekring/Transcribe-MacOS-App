import Foundation
import AVFoundation
import TranscribeKit

/// Microphone recording via AVAudioSession/AVAudioRecorder (the iOS
/// counterpart of the Mac app's AudioRecorderManager, which uses CoreAudio
/// device selection that doesn't exist on iOS). Records mono AAC at 48 kHz —
/// the shared AudioPreprocessor converts to 16 kHz WAV before WhisperKit.
@MainActor
final class RecordingService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var level: Float = 0          // 0...1 for the meter
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String?
    /// Rolling level history for the waveform display (newest last)
    @Published var levelHistory: [Float] = []

    static let historyLength = 160

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private(set) var fileURL: URL?

    nonisolated static func recordingsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() {
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = Self.recordingsDirectory()
                .appendingPathComponent("Inspelning \(formatter.string(from: Date())).m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                errorMessage = localized("ios_recording_failed")
                return
            }
            recorder = rec
            fileURL = url
            isRecording = true
            isPaused = false
            duration = 0
            levelHistory = []
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            errorMessage = localized("ios_recording_failed") + " " + error.localizedDescription
        }
    }

    func pause() {
        recorder?.pause()
        isPaused = true
    }

    func resume() {
        recorder?.record()
        isPaused = false
    }

    /// Stops and returns the finished recording's URL.
    func stop() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        isPaused = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return fileURL
    }

    /// Stops and deletes the recording (user cancelled).
    func discard() {
        if let url = stop() {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }

    private func tick() {
        guard let recorder, isRecording, !isPaused else { return }
        recorder.updateMeters()
        // Average power is in dBFS (−160...0); map −50...0 to 0...1
        let db = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (db + 50) / 50))
        levelHistory.append(level)
        if levelHistory.count > Self.historyLength {
            levelHistory.removeFirst(levelHistory.count - Self.historyLength)
        }
        duration = recorder.currentTime
    }
}
