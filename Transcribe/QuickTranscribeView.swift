import SwiftUI
import AVFoundation

struct QuickTranscribeView: View {
    @StateObject private var recorder = AudioRecorder()
    @State private var transcriptionText = ""
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var errorMessage: String? = nil
    @State private var transcriptionService: TranscriptionService? = nil
    @State private var transcriptionTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 20) {
            Text("Quick Transcribe")
                .font(.title2)
                .bold()

            if isRecording {
                audioWaveform
            }

            ScrollView {
                Text(transcriptionText.isEmpty ? "Start recording to transcribe..." : transcriptionText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
            .frame(height: 150)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 20) {
                recordButton

                if !transcriptionText.isEmpty {
                    copyButton
                    clearButton
                }
            }

            if isTranscribing {
                ProgressView("Transcribing...")
                    .progressViewStyle(.linear)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
        .onDisappear {
            transcriptionTask?.cancel()
            transcriptionService?.cancelTranscription()
            if isRecording {
                _ = recorder.stopRecording()
            }
        }
    }

    var audioWaveform: some View {
        HStack(spacing: 2) {
            ForEach(0..<20, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: CGFloat.random(in: 10...40))
                    .animation(.easeInOut(duration: 0.2).repeatForever(), value: isRecording)
            }
        }
        .frame(height: 50)
    }

    var recordButton: some View {
        Button(action: toggleRecording) {
            Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(isRecording ? .red : .accentColor)
        }
        .buttonStyle(.plain)
        .disabled(isTranscribing)
    }

    var copyButton: some View {
        Button(action: copyToClipboard) {
            Label("Copy", systemImage: "doc.on.clipboard")
        }
    }

    var clearButton: some View {
        Button(action: clearTranscription) {
            Label("Clear", systemImage: "trash")
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        errorMessage = nil
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            errorMessage = localized("mic_permission_message")
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        beginRecording()
                    } else {
                        errorMessage = localized("mic_permission_message")
                    }
                }
            }
        @unknown default:
            break
        }
    }

    func beginRecording() {
        if recorder.startRecording() {
            isRecording = true
        } else {
            errorMessage = localized("recording_error")
        }
    }

    func stopRecording() {
        let audioURL = recorder.stopRecording()
        isRecording = false

        if let url = audioURL {
            transcribeAudio(url)
        }
    }

    func transcribeAudio(_ url: URL) {
        isTranscribing = true
        errorMessage = nil

        transcriptionTask = Task { @MainActor in
            let service = TranscriptionService()
            transcriptionService = service

            do {
                for try await update in service.transcribe(fileURL: url) {
                    // Low-progress updates are status messages (model loading, init, etc.)
                    if update.progress >= 0.15 || update.isComplete {
                        transcriptionText = update.text
                    }
                    if update.isComplete {
                        break
                    }
                }
            } catch is CancellationError {
                // User-initiated stop — no error UI
            } catch {
                errorMessage = error.localizedDescription
            }

            isTranscribing = false
            transcriptionService = nil
            transcriptionTask = nil
        }
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptionText, forType: .string)
    }

    func clearTranscription() {
        transcriptionText = ""
        errorMessage = nil
    }
}

class AudioRecorder: ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    /// Starts recording to a temporary file. Returns false if the recorder could not be created or started.
    func startRecording() -> Bool {
        // macOS doesn't require AVAudioSession configuration
        do {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("Transcribe")
                .appendingPathComponent("QuickRecordings")

            // Create directory if it doesn't exist
            try? FileManager.default.createDirectory(at: tempDir,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)

            let audioFilename = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
            recordingURL = audioFilename

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            return audioRecorder?.record() ?? false
        } catch {
            recordingURL = nil
            return false
        }
    }

    func stopRecording() -> URL? {
        audioRecorder?.stop()
        return recordingURL
    }
}
