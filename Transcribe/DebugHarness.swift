#if DEBUG
import AVFoundation
import AppKit
import SwiftUI
import TranscribeKit

/// Launch-argument hooks for driving the app without a person at the
/// microphone — for screenshots and end-to-end checks. Debug builds only.
///
///   -debugScreen recording|systemAudio   open that screen at launch
///   -debugLiveDemo sv|en                 on the recording screen, record
///                                        synthesised speech through the real
///                                        pipeline (file, meter, live text)
///   -debugTranscribeDemo sv|en           synthesise speech to a file and
///                                        open it for transcription
///   -debugRecordSeconds N                on the recording screen, record the
///                                        real input device for N seconds
///   -debugInputDevice NAME               with -debugRecordSeconds: pick the
///                                        input device whose name contains NAME
///   -debugShowModelPicker 1              open the model picker at launch
///   -debugSettingsSection NAME           open Settings on that section
///                                        (general, apiKeys, localModels, …)
///   -debugShowYouTube 1                  open the YouTube sheet at launch
///   -debugShowAbout 1 / -debugShowQuick 1 open the About / Quick Transcribe window
///   -debugShowHelp 1                     open the help window at launch
///   -debugHelpScroll NAME                with -debugShowHelp: scroll the help to
///                                        record, transcript or privacy
///   -debugHold 1                         with -debugLiveDemo: don't stop at
///                                        the end of the speech
///   -debugThenTranscribe 1               with -debugLiveDemo: press
///                                        Transcribe once the recording ends
@MainActor
enum DebugHarness {
    private static var arguments: UserDefaults { .standard }

    static var initialScreen: AppState.Screen? {
        switch arguments.string(forKey: "debugScreen") {
        case "recording": return .recording
        case "systemAudio": return .systemAudio
        default: return nil
        }
    }

    private static let swedish = """
    Välkommen till dagens möte. Vi ska gå igenom tre punkter på dagordningen. \
    Först tittar vi på budgeten för nästa kvartal, och sedan diskuterar vi rekryteringen av två nya utvecklare till teamet i Göteborg. \
    Avslutningsvis behöver vi bestämma ett datum för sommarfesten. \
    Jag föreslår att vi börjar med budgeten, eftersom den påverkar allt annat. \
    Förra året gick vi över budget, främst på grund av ökade kostnader för molntjänster. \
    I år vill jag att vi håller oss inom ramarna. Finns det några frågor innan vi sätter igång?
    """

    private static let english = """
    Good morning everyone, and thank you for joining. \
    Today we are going to review the quarterly results and talk about the roadmap for next year. \
    Revenue grew strongly, mostly because of the new subscription plan. \
    After that, we will open the floor for questions.
    """

    private static func script(for code: String) -> (text: String, voice: String) {
        code == "en" ? (english, "en-US") : (swedish, "sv-SE")
    }

    /// Runs at launch from the root view.
    static func runLaunchHooks(appState: AppState) {
        if let screen = initialScreen {
            appState.navigate(to: screen)
        }
        if let delegate = AppDelegate.shared {
            if arguments.bool(forKey: "debugShowAbout") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { delegate.showAboutWindow() }
            }
            if arguments.bool(forKey: "debugShowQuick") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { delegate.quickTranscribe() }
            }
        }
        if let code = arguments.string(forKey: "debugTranscribeDemo") {
            Task {
                let (text, voice) = script(for: code)
                guard let buffers = await synthesise(text, voice: voice), let first = buffers.first else { return }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Transcribe").appendingPathComponent("Recordings")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("demo-\(code).wav")
                try? FileManager.default.removeItem(at: url)
                guard let file = try? AVAudioFile(forWriting: url, settings: first.format.settings) else { return }
                for buffer in buffers { try? file.write(from: buffer) }
                file.close()
                appState.openFileForTranscription(url)
            }
        }
    }

    /// Called by the recording screen before it starts its microphone.
    static func attach(to capture: MicrophoneCapture, start: @escaping () -> Void, transcribe: @escaping () -> Void) {
        let recordSeconds = arguments.double(forKey: "debugRecordSeconds")
        if recordSeconds > 0 {
            // The real capture path: engine, device binding, tap, file.
            let deviceName = arguments.string(forKey: "debugInputDevice")
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let deviceName, let device = capture.inputDevices.first(where: { $0.name.localizedCaseInsensitiveContains(deviceName) }) {
                    capture.selectedDeviceID = device.id
                }
                try? await Task.sleep(for: .seconds(1))
                start()
                try? await Task.sleep(for: .seconds(recordSeconds))
                if capture.isRecording { start() }
                if arguments.bool(forKey: "debugThenTranscribe") {
                    try? await Task.sleep(for: .seconds(3))
                    transcribe()
                }
            }
            return
        }
        guard let code = arguments.string(forKey: "debugLiveDemo") else { return }
        capture.usesInjectedAudio = true
        let hold = arguments.bool(forKey: "debugHold")

        Task {
            let (text, voice) = script(for: code)
            guard let buffers = await synthesise(text, voice: voice) else { return }
            try? await Task.sleep(for: .seconds(1))
            start()
            for buffer in slices(of: buffers, seconds: 0.1) {
                capture.debugInject(buffer)
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !hold else { return }
            try? await Task.sleep(for: .seconds(2))
            if capture.isRecording { start() }
            if arguments.bool(forKey: "debugThenTranscribe") {
                try? await Task.sleep(for: .seconds(3))
                transcribe()
            }
        }
    }

    // MARK: - Speech

    /// Speech from a system voice as 48 kHz mono float buffers.
    private static func synthesise(_ text: String, voice language: String) async -> [AVAudioPCMBuffer]? {
        guard let voice = AVSpeechSynthesisVoice(language: language) else { return nil }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        let synthesizer = AVSpeechSynthesizer()
        let collector = SpeechCollector()
        synthesizer.delegate = collector
        let raw: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            collector.onFinish(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
                collector.append(pcm)
            }
        }
        synthesizer.delegate = nil
        return convert(raw)
    }

    private static func convert(_ buffers: [AVAudioPCMBuffer]) -> [AVAudioPCMBuffer]? {
        guard let first = buffers.first,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: first.format, to: target) else { return nil }
        var output: [AVAudioPCMBuffer] = []
        var queue = buffers[...]
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 48_000) else { break }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
                if let next = queue.popFirst() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if error != nil { return nil }
            if chunk.frameLength > 0 { output.append(chunk) }
            if status == .endOfStream || chunk.frameLength == 0 { break }
        }
        return output
    }

    /// Re-cuts buffers into tap-sized pieces.
    private static func slices(of buffers: [AVAudioPCMBuffer], seconds: Double) -> [AVAudioPCMBuffer] {
        guard let format = buffers.first?.format else { return [] }
        let size = AVAudioFrameCount(format.sampleRate * seconds)
        var samples: [Float] = []
        for buffer in buffers {
            if let channel = buffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
        }
        var result: [AVAudioPCMBuffer] = []
        var index = 0
        while index < samples.count {
            let count = min(Int(size), samples.count - index)
            guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) else { break }
            slice.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress, let destination = slice.floatChannelData?[0] {
                    destination.update(from: base + index, count: count)
                }
            }
            result.append(slice)
            index += count
        }
        return result
    }
}

private final class SpeechCollector: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
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
#endif
