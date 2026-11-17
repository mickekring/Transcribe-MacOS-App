import Foundation
import TranscribeKit

/// Drives live text for a recording screen: owns the `LiveTranscriptionSession`
/// and publishes its transcript for the view.
///
/// Recording must start the instant the user presses the button, but the
/// model may still be loading. Audio is therefore accepted straight away and
/// held in a relay until the session exists, then replayed in order — the
/// first words are transcribed late, never lost.
@MainActor
final class LiveTranscriptController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Loading the model; audio is being buffered.
        case preparing
        case listening
        /// Recording stopped; decoding what is left.
        case finishing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Text that will not change any more.
    @Published private(set) var confirmed = ""
    /// Text still being revised as more audio arrives.
    @Published private(set) var volatile = ""
    /// Display name of the model producing the live text.
    @Published private(set) var modelName = ""

    private var session: LiveTranscriptionSession?
    private var relay: LiveAudioRelay?
    private var startTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    /// Bumped on every start/reset so a late model load can't attach to a
    /// recording that has already ended.
    private var generation = 0

    var hasText: Bool { !confirmed.isEmpty || !volatile.isEmpty }
    var isActive: Bool { phase == .preparing || phase == .listening || phase == .finishing }

    /// Begins a live session. Returns the sink to hand to the audio source;
    /// it can be called from any thread, immediately.
    func start(modelId: String, languageCode: String) -> @Sendable ([Float]) -> Void {
        reset()
        generation += 1
        let current = generation
        let relay = LiveAudioRelay()
        self.relay = relay
        modelName = ModelManager.shared.displayName(for: modelId)
        phase = .preparing

        startTask = Task { [weak self] in
            do {
                let session = try await ParakeetService.shared.makeLiveSession(
                    modelId: modelId,
                    language: languageCode == "auto" ? nil : languageCode
                )
                guard let self, self.generation == current, !Task.isCancelled else {
                    await session.cancel()
                    return
                }
                self.session = session
                await session.start()
                relay.attach(session)
                if self.phase == .preparing { self.phase = .listening }

                self.updatesTask = Task { [weak self] in
                    for await update in session.updates {
                        guard let self, self.generation == current else { return }
                        self.confirmed = update.confirmed
                        self.volatile = update.volatile
                    }
                }
            } catch {
                guard let self, self.generation == current else { return }
                self.relay = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
        return { samples in relay.push(samples) }
    }

    /// Recording ended: decode the remaining audio and settle the text.
    func finish() async {
        guard isActive else { return }
        phase = .finishing
        // If the model is still loading, wait for it so buffered audio is transcribed
        await startTask?.value
        guard let session else {
            if case .failed = phase { return }
            phase = .idle
            return
        }
        let current = generation
        let text = await session.finish()
        await updatesTask?.value
        guard generation == current else { return }
        confirmed = text
        volatile = ""
        self.session = nil
        relay = nil
        phase = .idle
    }

    /// Stops any session and clears the transcript.
    func reset() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        relay?.detach()
        relay = nil
        if let session {
            Task { await session.cancel() }
        }
        session = nil
        confirmed = ""
        volatile = ""
        phase = .idle
    }
}

/// Hands audio from the capture thread to the session, buffering until the
/// session is ready. Attaching replays the backlog under the same lock that
/// guards `push`, so samples reach the session in the order they were captured.
private final class LiveAudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var session: LiveTranscriptionSession?
    private var backlog: [[Float]] = []
    private var detached = false
    /// About two minutes at 100 ms per buffer — far longer than any model load.
    private let maxBacklog = 1_200

    func push(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !detached else { return }
        if let session {
            session.append(samples)
        } else if backlog.count < maxBacklog {
            backlog.append(samples)
        }
    }

    func attach(_ session: LiveTranscriptionSession) {
        lock.lock()
        defer { lock.unlock() }
        guard !detached else { return }
        for samples in backlog {
            session.append(samples)
        }
        backlog.removeAll()
        self.session = session
    }

    func detach() {
        lock.lock()
        defer { lock.unlock() }
        detached = true
        session = nil
        backlog.removeAll()
    }
}
