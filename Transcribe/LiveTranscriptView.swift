import SwiftUI
import AppKit
import TranscribeKit

/// Live-transcription switch shown before recording. Offers the Pianissimo
/// download when the model is missing.
struct LiveTranscriptionToggle: View {
    @Binding var isOn: Bool
    @ObservedObject private var modelManager = ModelManager.shared

    private let modelId = PianissimoService.modelId

    var body: some View {
        let available = modelManager.isModelDownloaded(modelId)
        let downloading = modelManager.isDownloading[modelId] == true

        VStack(spacing: 6) {
            Toggle(isOn: Binding(get: { isOn && available }, set: { isOn = $0 })) {
                Label(localized("live_transcription"), systemImage: "captions.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(available ? .textPrimary : .textTertiary)
            }
            .toggleStyle(.switch)
            .tint(.primaryAccent)
            .disabled(!available)
            .frame(maxWidth: 280)

            if available {
                Text(localized("live_transcription_subtitle"))
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
            } else if downloading {
                HStack(spacing: 6) {
                    AccentSpinner(size: 11, lineWidth: 1.5)
                    Text(String(format: localized("downloading_model"), modelManager.displayName(for: modelId)))
                    Text("\(Int((modelManager.downloadProgress[modelId] ?? 0) * 100))%")
                        .monospacedDigit()
                        .foregroundColor(.primaryAccent)
                }
                .font(.system(size: 11))
                .foregroundColor(.textSecondary)
            } else {
                HStack(spacing: 6) {
                    Text(localized("live_transcription_requires_model"))
                        .foregroundColor(.textTertiary)
                    Button {
                        isOn = true
                        Task { try? await WhisperKitService.shared.downloadOnly(modelId: modelId) }
                    } label: {
                        Text("\(localized("download")) (\(modelManager.getModelSizeString(modelId)))")
                            .foregroundColor(.primaryAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(UserDefaults.standard.bool(forKey: "localOnlyMode"))
                }
                .font(.system(size: 11))
            }
        }
    }
}

/// Scrolling live transcript: committed text in full color, the still
/// changing tail dimmed.
struct LiveTranscriptPanel: View {
    @ObservedObject var live: LiveTranscriber
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(live.state == .running ? Color.red : Color.textTertiary)
                    .frame(width: 8, height: 8)
                Text(localized("live_transcription"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)
                Spacer()
                if live.state == .finished && !live.displayText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(live.displayText, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? localized("live_copied") : localized("copy_text"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primaryAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    let separator = live.confirmedText.isEmpty || live.volatileText.isEmpty ? "" : " "
                    Text("\(Text(live.confirmedText).foregroundStyle(Color.textPrimary))\(separator)\(Text(live.volatileText).foregroundStyle(Color.textTertiary))")
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: live.displayText) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 640)
        .frame(height: 180)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.borderLight, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 24)
    }

    private var statusText: String {
        switch live.state {
        case .idle: return ""
        case .loading: return localized("live_preparing")
        case .running: return live.displayText.isEmpty ? localized("live_listening") : ""
        case .finished: return localized("live_finished_hint")
        case .failed(let message): return String(format: localized("live_failed"), message)
        }
    }
}
