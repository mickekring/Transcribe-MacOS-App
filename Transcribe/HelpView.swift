import SwiftUI
import TranscribeKit

/// The in-app help: how to use the app, and how it handles data. One page in
/// the in-app language, opened from the toolbar's question mark, the Help
/// menu (⌘?), the home screen's footer and the status-bar menu.
///
/// Like the transcript, the text sits directly on the backdrop; the only
/// surface is the tinted privacy promise at the top.
struct HelpView: View {
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @Environment(\.openURL) private var openURL

    private enum Anchor: String, Hashable { case record, transcript, privacy }

    static let projectURL = URL(string: "https://github.com/mickekring/Transcribe-MacOS-App")!

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    header
                    promise {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(Anchor.privacy, anchor: .top)
                        }
                    }
                    gettingStarted
                    models
                    HelpSection(icon: "mic", title: "help_record_title") {
                        HelpParagraph("help_record_body")
                        HelpBullets(["help_record_1", "help_record_2", "help_record_3"])
                    }
                    .id(Anchor.record)
                    HelpSection(icon: "speaker.wave.2", title: "help_system_title") {
                        HelpParagraph("help_system_body")
                        HelpBullets(["help_system_1", "help_system_2"])
                    }
                    HelpSection(icon: "doc.badge.arrow.up", title: "help_files_title") {
                        HelpParagraph("help_files_body")
                        HelpBullets(["help_files_1"])
                    }
                    HelpSection(icon: "text.alignleft", title: "help_transcript_title") {
                        HelpParagraph("help_transcript_body")
                        HelpBullets((1...5).map { "help_transcript_\($0)" })
                    }
                    .id(Anchor.transcript)
                    shortcuts
                    privacy
                        .id(Anchor.privacy)
                    support
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 12)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            #if DEBUG
            .onAppear {
                // -debugHelpScroll record|transcript|privacy (see DebugHarness)
                if let name = UserDefaults.standard.string(forKey: "debugHelpScroll"), let anchor = Anchor(rawValue: name) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(anchor, anchor: .top) }
                }
            }
            #endif
        }
        .background(AuroraBackdrop(intensity: 0.6))
        .navigationTitle(localized("help_title"))
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("help_title"))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryAccent)
            Text(localized("help_subtitle"))
                .font(.title3)
                .foregroundStyle(Color.textSecondary)
        }
    }

    /// The privacy promise, up front: it is what the local models are for.
    private func promise(readMore: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.primaryAccent.opacity(0.18))
                    .frame(width: 52, height: 52)
                Image(systemName: "lock.shield")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.primaryAccent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("help_promise_title"))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HelpParagraph("help_promise_body")
                Button(action: readMore) {
                    Label(localized("help_promise_more"), systemImage: "arrow.down")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primaryAccent)
                .pointerStyle(.link)
                .padding(.top, 2)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primaryAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }

    private var gettingStarted: some View {
        HelpSection(icon: "sparkles", title: "help_start_title") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(1...3, id: \.self) { step in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(step)")
                            .font(.system(.callout, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.primaryAccent)
                            .frame(width: 28, height: 28)
                            .background(Color.primaryAccent.opacity(0.14), in: Circle())
                            .accessibilityHidden(true)
                        HelpParagraph("help_start_\(step)")
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var models: some View {
        HelpSection(icon: "laptopcomputer", title: "help_models_title") {
            HelpParagraph("help_models_body")
            HelpBullets((1...6).map { "help_models_\($0)" })
            HelpParagraph("help_models_note")
        }
    }

    private var shortcuts: some View {
        HelpSection(icon: "keyboard", title: "help_shortcuts_title") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                shortcutRow("⌘O", "help_shortcut_open")
                shortcutRow("⌘R", "help_shortcut_record")
                shortcutRow(localized("help_key_space"), "help_shortcut_space")
                shortcutRow("⌘,", "help_shortcut_settings")
                shortcutRow("⌘?", "help_shortcut_help")
            }
            HelpParagraph("help_shortcuts_menubar")
        }
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .gridColumnAlignment(.trailing)
            Text(localized(action))
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var privacy: some View {
        HelpSection(icon: "lock.shield", title: "help_data_title") {
            HelpParagraph("help_data_intro")
            VStack(alignment: .leading, spacing: 16) {
                privacyItem("laptopcomputer", "help_data_local")
                privacyItem("cloud", "help_data_cloud")
                privacyItem("text.bubble", "help_data_ollama")
                privacyItem("arrow.down.circle", "help_data_downloads")
                privacyItem("trash", "help_data_temp")
                privacyItem("key", "help_data_keys")
                privacyItem("eye.slash", "help_data_tracking")
                privacyItem("wifi.slash", "help_data_localonly")
            }
            .padding(.top, 4)
        }
    }

    private func privacyItem(_ icon: String, _ key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.primaryAccent)
                .frame(width: 22)
                .accessibilityHidden(true)
            HelpParagraph(key)
        }
    }

    private var support: some View {
        HelpSection(icon: "questionmark.bubble", title: "help_support_title") {
            HelpParagraph("help_support_body")
            HStack(spacing: 14) {
                Button {
                    openURL(Self.projectURL)
                } label: {
                    Label(localized("help_support_link"), systemImage: "arrow.up.right")
                }
                .glassAction()

                Text(String(
                    format: localized("version_format"),
                    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                ))
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Building blocks

/// A topic: an icon in a tinted circle, a heading, then its content.
private struct HelpSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primaryAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.primaryAccent.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                Text(localized(title))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
    }
}

/// A paragraph from the string tables. `**bold**` marks the names of
/// buttons and settings, drawn in the primary text colour so they stand out.
private struct HelpParagraph: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(Self.styled(localized(key)))
            .font(.body)
            .foregroundStyle(Color.textSecondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    static func styled(_ text: String) -> AttributedString {
        guard var styled = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        for run in styled.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            styled[run.range].foregroundColor = Color.textPrimary
        }
        return styled
    }
}

private struct HelpBullets: View {
    let keys: [String]

    init(_ keys: [String]) {
        self.keys = keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(keys, id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("•")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color.primaryAccent)
                        .accessibilityHidden(true)
                    HelpParagraph(key)
                }
            }
        }
    }
}
