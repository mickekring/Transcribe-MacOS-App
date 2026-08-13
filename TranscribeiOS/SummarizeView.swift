import SwiftUI
import TranscribeKit
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// On-device (Gemma/Qwen via MLX) or cloud (Berget) text processing of a
/// transcript. Outputs persist on the record — reopening shows the latest
/// generated text per prompt — and can be edited in place.
struct SummarizeView: View {
    let record: TranscriptRecord
    @ObservedObject var store: TranscriptStore
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
    @State private var isEditing = false
    @State private var stats: String?
    @State private var currentProcessedId: UUID?
    @State private var generationTask: Task<Void, Never>?

    @MainActor private static var loadedOnce = false

    private var transcriptText: String {
        record.speakerTranscript ?? record.text
    }

    private var selectedPrompt: TextProcessingPrompt? {
        prompts.first { $0.id == selectedPromptId } ?? prompts.first
    }

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
                .disabled(isWorking || isEditing)

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

                if isWorking && output.contains("<think>") && Self.stripThinking(output).isEmpty {
                    // Reasoning models emit hidden thinking before the answer
                    Text(localized("ios_llm_thinking"))
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }

                if isEditing {
                    TextEditor(text: $output)
                        .font(.callout)
                        .foregroundColor(.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal)
                } else {
                    ScrollView {
                        MarkdownText(Self.stripThinking(output))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                }

                HStack(spacing: 10) {
                    llmPicker
                        .menuStyle(.button)
                        .disabled(isWorking || isEditing)
                        .frame(maxWidth: .infinity)

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
                    .disabled(isEditing)
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
                ToolbarItemGroup(placement: .primaryAction) {
                    if !output.isEmpty && !isWorking {
                        Button {
                            if isEditing { saveEdit() }
                            isEditing.toggle()
                        } label: {
                            Image(systemName: isEditing ? "checkmark" : "pencil")
                        }
                        if !isEditing {
                            ShareLink(item: output) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .onAppear {
                if selectedPromptId == nil { selectedPromptId = prompts.first?.id }
                llmDownloads.refresh()
                loadStoredOutput()
                if output.isEmpty && !Self.loadedOnce && !selectedLLM.hasPrefix("berget:") {
                    statusInfo = localized("ios_llm_download_note")
                }
            }
            .onChange(of: selectedPromptId) { _, _ in
                guard !isWorking, !isEditing else { return }
                loadStoredOutput()
            }
        }
    }

    // MARK: - Persistence

    /// Shows the latest saved output for the selected prompt, if any.
    private func loadStoredOutput() {
        guard let prompt = selectedPrompt,
              let stored = store.records.first(where: { $0.id == record.id })?
                  .latestProcessed(promptName: prompt.name) else {
            output = ""
            isDone = false
            currentProcessedId = nil
            stats = nil
            status = ""
            return
        }
        output = stored.text
        currentProcessedId = stored.id
        isDone = true
        stats = nil
        status = ""
    }

    private func saveGenerated(promptName: String) {
        let entry = ProcessedText(id: UUID(), promptName: promptName,
                                  model: selectedLLM, date: Date(), text: output)
        currentProcessedId = entry.id
        store.modify(record.id) { rec in
            rec.processedTexts = (rec.processedTexts ?? []) + [entry]
        }
    }

    private func saveEdit() {
        guard let id = currentProcessedId else {
            if let prompt = selectedPrompt { saveGenerated(promptName: prompt.name) }
            return
        }
        store.modify(record.id) { rec in
            if let index = rec.processedTexts?.firstIndex(where: { $0.id == id }) {
                rec.processedTexts?[index].text = output
            }
        }
    }

    // MARK: - LLM selection

    /// Picker over available LLMs: downloaded local models plus Berget's
    /// catalog when a key is configured.
    private var llmPicker: some View {
        Menu {
            Picker("", selection: $selectedLLM) {
                Section(localized("ios_local_models_header")) {
                    ForEach(LocalLLMModel.all.filter { llmDownloads.downloaded.contains($0.id) }) { model in
                        Label(model.name, systemImage: "cpu").tag(model.id)
                    }
                }
                if !(KeychainHelper.get("bergetAPIKey") ?? "").isEmpty {
                    Section(localized("ios_cloud_models_header")) {
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
        .menuOrder(.fixed)
    }

    private var selectedLLMLabel: String {
        if selectedLLM.hasPrefix("berget:") {
            let apiId = String(selectedLLM.dropFirst("berget:".count))
            return bergetCatalog.llmModels.first { $0.id == apiId }?.name
                ?? apiId.components(separatedBy: "/").last ?? apiId
        }
        return LocalLLMModel.byId(selectedLLM)?.shortName ?? selectedLLM
    }

    /// Removes reasoning-model deliberation (<think>…</think> blocks; an
    /// unterminated block hides everything after it).
    static func stripThinking(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>",
                                      range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Markdown rendering

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

    // MARK: - Generation

    private func run() {
        guard let prompt = selectedPrompt else { return }
        isWorking = true
        isDone = false
        output = ""
        stats = nil
        currentProcessedId = nil

        generationTask = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                if selectedLLM.hasPrefix("berget:") {
                    try await runBerget(prompt: prompt)
                } else {
                    try await runLocal(prompt: prompt)
                }
                saveGenerated(promptName: prompt.name)
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

        // Gemma has no separate system role — instruction and content go in
        // one user turn, same shape LLMService uses for Berget. Qwen thinks
        // by default; the /no_think soft switch turns reasoning off so it
        // answers instead of deliberating for minutes.
        let noThink = model.repo.lowercased().contains("qwen") ? "\n/no_think" : ""
        let fullPrompt = """
        \(prompt.prompt)

        \(transcriptText)\(noThink)
        """

        let generationStart = Date()
        var tokenCount = 0
        let session = ChatSession(container)
        for try await token in session.streamResponse(to: fullPrompt) {
            try Task.checkCancellation()
            output += token
            tokenCount += 1
            // Hard cap: a runaway generation (reasoning loops) grows the KV
            // cache without bound and eventually jetsams the app
            if tokenCount >= 8192 { break }
        }
        let generationSeconds = Date().timeIntervalSince(generationStart)
        output = Self.stripThinking(output)

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
