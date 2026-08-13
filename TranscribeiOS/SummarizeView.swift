import SwiftUI
import TranscribeKit
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// On-device text processing with Gemma 4 E2B (4-bit) via MLX.
/// Spike goals: measure model load time, generation speed, and memory
/// headroom on-device, and judge Swedish summary quality against Berget.
struct SummarizeView: View {
    let transcriptText: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = LocalizationManager.shared

    @AppStorage("iosSelectedLLM") private var selectedLLM = "e2b"
    @ObservedObject private var llmDownloads = LLMDownloadManager.shared
    @ObservedObject private var bergetCatalog = BergetModelCatalog.shared
    @State private var prompts = SettingsManager.defaultPrompts()
    @State private var selectedPromptId: UUID?
    @State private var status = ""
    @State private var statusInfo = ""
    @State private var output = ""
    @State private var isWorking = false
    @State private var isDone = false
    @State private var stats: String?
    @State private var generationTask: Task<Void, Never>?

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
                    MarkdownText(output)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .defaultScrollAnchor(.bottom)

                HStack(spacing: 10) {
                    llmPicker
                        .menuStyle(.button)
                        .disabled(isWorking)
                        .frame(maxWidth: .infinity)

                    if isDone {
                        ShareLink(item: output) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(minWidth: 24)
                        }
                    }

                    Button {
                        if isWorking {
                            generationTask?.cancel()
                        } else {
                            run()
                        }
                    } label: {
                        Label(isWorking ? localized("cancel") : localized("ios_process"),
                              systemImage: isWorking ? "stop.circle" : "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .padding(.horizontal)
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
                llmDownloads.refresh()
                if !Self.loadedOnce && !selectedLLM.hasPrefix("berget:") {
                    statusInfo = localized("ios_llm_download_note")
                }
            }
        }
    }

    /// Picker over available LLMs: downloaded local models plus Berget's
    /// catalog when a key is configured.
    private var llmPicker: some View {
        Menu {
            Section(localized("ios_local_models_header")) {
                Picker("", selection: $selectedLLM) {
                    ForEach(LocalLLMModel.all.filter { llmDownloads.downloaded.contains($0.id) }) { model in
                        Label(model.name, systemImage: "cpu").tag(model.id)
                    }
                }
            }
            if !(KeychainHelper.get("bergetAPIKey") ?? "").isEmpty {
                Section(localized("ios_cloud_models_header")) {
                    Picker("", selection: $selectedLLM) {
                        ForEach(bergetCatalog.llmModels) { model in
                            Label(model.name, systemImage: "cloud").tag("berget:\(model.id)")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selectedLLM.hasPrefix("berget:") ? "cloud" : "cpu")
                Text(selectedLLMLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
        }
    }

    private var selectedLLMLabel: String {
        if selectedLLM.hasPrefix("berget:") {
            let apiId = String(selectedLLM.dropFirst("berget:".count))
            return bergetCatalog.llmModels.first { $0.id == apiId }?.name
                ?? apiId.components(separatedBy: "/").last ?? apiId
        }
        return LocalLLMModel.byId(selectedLLM)?.shortName ?? selectedLLM
    }

    /// Lightweight Markdown renderer for LLM output: headers, bullet and
    /// numbered lists as blocks, inline **bold**/*italic* via AttributedString.
    /// Cheap enough to re-render on every streamed token.
    private struct MarkdownText: View {
        let text: String

        init(_ text: String) { self.text = text }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    render(line)
                }
            }
            .textSelection(.enabled)
        }

        @ViewBuilder
        private func render(_ line: String) -> some View {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                Text(inline(String(trimmed.dropFirst(4))))
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.textPrimary)
                    .padding(.top, 4)
            } else if trimmed.hasPrefix("## ") {
                Text(inline(String(trimmed.dropFirst(3))))
                    .font(.headline)
                    .foregroundColor(.textPrimary)
                    .padding(.top, 6)
            } else if trimmed.hasPrefix("# ") {
                Text(inline(String(trimmed.dropFirst(2))))
                    .font(.title3.bold())
                    .foregroundColor(.textPrimary)
                    .padding(.top, 6)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundColor(.primaryAccent)
                    Text(inline(String(trimmed.dropFirst(2))))
                        .font(.callout)
                        .foregroundColor(.textPrimary)
                }
                .padding(.leading, 4)
            } else if !trimmed.isEmpty {
                Text(inline(trimmed))
                    .font(.callout)
                    .foregroundColor(.textPrimary)
            }
        }

        private func inline(_ line: String) -> AttributedString {
            (try? AttributedString(
                markdown: line,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(line)
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
                if selectedLLM.hasPrefix("berget:") {
                    try await runBerget(prompt: prompt)
                } else {
                    try await runLocal(prompt: prompt)
                }
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

    private func runLocal(prompt: TextProcessingPrompt) async throws {
        let model = LocalLLMModel.byId(selectedLLM) ?? LocalLLMModel.all[0]
        let loadStart = Date()
        if LLMRuntime.loadedRepo != model.repo {
            status = localized("ios_llm_loading")
        }
        let container = try await LLMRuntime.loadContainer(repo: model.repo) { fraction in
            Task { @MainActor in
                status = String(format: localized("ios_llm_downloading"),
                                Int(fraction * 100))
            }
        }
        let loadSeconds = Date().timeIntervalSince(loadStart)
        statusInfo = ""
        status = localized("ios_llm_generating")

        // Gemma has no separate system role — instruction and content
        // go in one user turn, same shape LLMService uses for Berget.
        let fullPrompt = """
        \(prompt.prompt)

        \(transcriptText)
        """

        let generationStart = Date()
        var tokenCount = 0
        let session = ChatSession(container)
        for try await token in session.streamResponse(to: fullPrompt) {
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
    }

    private func runBerget(prompt: TextProcessingPrompt) async throws {
        let model = String(selectedLLM.dropFirst("berget:".count))
        let apiKey = KeychainHelper.get("bergetAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            status = localized("ios_api_key_missing")
            return
        }
        statusInfo = ""
        status = localized("ios_llm_generating")
        for try await token in LLMService().streamCompletion(
            systemPrompt: prompt.prompt,
            userMessage: transcriptText,
            provider: .berget,
            model: model,
            apiKey: apiKey
        ) {
            try Task.checkCancellation()
            output += token
        }
        stats = nil
    }
}
