import SwiftUI
import TranscribeKit
import Gemma4Swift

/// On-device text processing with Gemma 4 E2B (4-bit) via MLX.
/// Spike goals: measure model load time, generation speed, and memory
/// headroom on-device, and judge Swedish summary quality against Berget.
struct SummarizeView: View {
    let transcriptText: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var prompts = SettingsManager.defaultPrompts()
    @State private var selectedPromptId: UUID?
    @State private var status = ""
    @State private var statusInfo = ""
    @State private var output = ""
    @State private var isWorking = false
    @State private var isDone = false
    @State private var stats: String?
    @State private var generationTask: Task<Void, Never>?

    /// One pipeline per app session — the model stays resident between runs.
    @MainActor private static var pipeline: Gemma4Pipeline?
    @MainActor private static var loadedOnce = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker(localized("ios_llm_prompt_label"), selection: $selectedPromptId) {
                    ForEach(prompts) { prompt in
                        Text(prompt.name).tag(Optional(prompt.id))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .disabled(isWorking)

                if isWorking || !status.isEmpty {
                    HStack(spacing: 10) {
                        if isWorking { AccentSpinner(size: 18) }
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if !statusInfo.isEmpty {
                    Text(statusInfo)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                if let stats {
                    Text(stats)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }

                ScrollView {
                    Text(output)
                        .font(.callout)
                        .foregroundColor(.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .defaultScrollAnchor(.bottom)

                HStack(spacing: 16) {
                    if isDone {
                        ShareLink(item: output) {
                            Label(localized("save_copy"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(isWorking ? localized("cancel") : localized("ios_summarize")) {
                        if isWorking {
                            generationTask?.cancel()
                        } else {
                            run()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surfaceBackground)
            .navigationTitle(localized("ios_summarize"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("ios_close")) {
                        generationTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if selectedPromptId == nil { selectedPromptId = prompts.first?.id }
                if !Self.loadedOnce {
                    statusInfo = localized("ios_llm_download_note")
                }
            }
        }
    }

    private func run() {
        guard let prompt = prompts.first(where: { $0.id == selectedPromptId }) ?? prompts.first else { return }
        isWorking = true
        isDone = false
        output = ""
        stats = nil

        generationTask = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let loadStart = Date()
                if Self.pipeline == nil {
                    status = localized("ios_llm_loading")
                    let pipeline = Gemma4Pipeline()
                    try await pipeline.load(.e2b4bit, downloadIfNeeded: true) { progress in
                        Task { @MainActor in
                            status = String(format: localized("ios_llm_downloading"),
                                            Int(progress.fraction * 100))
                        }
                    }
                    Self.pipeline = pipeline
                }
                let loadSeconds = Date().timeIntervalSince(loadStart)
                statusInfo = ""

                guard let pipeline = Self.pipeline else { return }
                status = localized("ios_llm_generating")

                // Gemma has no separate system role — instruction and content
                // go in one user turn, same shape LLMService uses for Berget.
                let fullPrompt = """
                \(prompt.prompt)

                \(transcriptText)
                """

                let generationStart = Date()
                var tokenCount = 0
                let stream = try pipeline.chatStream(prompt: fullPrompt)
                for try await token in stream {
                    try Task.checkCancellation()
                    output += token
                    tokenCount += 1
                }
                let generationSeconds = Date().timeIntervalSince(generationStart)

                let tokensPerSecond = generationSeconds > 0
                    ? Double(tokenCount) / generationSeconds : 0
                stats = String(format: localized("ios_llm_stats"),
                               String(format: "%.1f", loadSeconds),
                               String(format: "%.1f", tokensPerSecond))
                Self.loadedOnce = true
                status = localized("ios_llm_done")
                isDone = true
            } catch is CancellationError {
                status = ""
            } catch {
                status = String(format: localized("ios_error"), error.localizedDescription)
            }
            isWorking = false
        }
    }
}
