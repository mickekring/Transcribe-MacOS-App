import SwiftUI
import TranscribeKit

struct AboutView: View {
    // Re-renders the window when the app language changes while it is open
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    /// The models and libraries the app ships or builds on. Two of the models
    /// are licensed CC BY 4.0, which requires this credit. These are proper
    /// names and are the same in every language.
    private static let acknowledgements = [
        "Pianissimo — Klang AI (CC BY 4.0)",
        "Parakeet TDT 0.6B v3 — NVIDIA (CC BY 4.0)",
        "KB Whisper — KBLab",
        "NB Whisper — NbAiLab",
        "WhisperKit — Argmax",
        "FluidAudio — FluidInference",
    ]

    private var preferredScheme: ColorScheme? {
        switch appColorScheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    /// The product name is not translated; it comes from the bundle.
    var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)

                Text(appName)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.textPrimary)

                Text(String(format: localized("version_format"), appVersion, buildNumber))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)

                Text(localized("about_tagline"))
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .padding(.top, 6)
            }
            .multilineTextAlignment(.center)

            // The window has a fixed size, so the middle scrolls rather than
            // clips when a translation runs longer.
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        featureRow(localized("about_feature_live"))
                        featureRow(localized("about_feature_nordic"))
                        featureRow(localized("about_feature_languages"))
                        featureRow(localized("about_feature_llm"))
                        featureRow(localized("about_feature_privacy"))
                        featureRow(localized("about_feature_built"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard()

                    VStack(spacing: 5) {
                        Text(localized("about_acknowledgements"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 2) {
                            ForEach(Self.acknowledgements, id: \.self) { line in
                                Text(line)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 5) {
                Text(localized("about_credits"))
                    .foregroundStyle(Color.textPrimary)
                HStack(spacing: 6) {
                    Text(localized("about_license"))
                        .foregroundStyle(Color.textSecondary)
                    Text("·")
                        .foregroundStyle(Color.textTertiary)
                        .accessibilityHidden(true)
                    Link(localized("about_source_link"), destination: URL(string: "https://github.com/mickekring/Transcribe-MacOS-App")!)
                        .foregroundStyle(Color.primaryAccent)
                        .pointerStyle(.link)
                }
            }
            .font(.caption)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 440, height: 556)
        // A window of its own, so it brings the app's backdrop with it
        .background { AuroraBackdrop() }
        .preferredColorScheme(preferredScheme)
    }

    func featureRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.primaryAccent)
        }
    }
}
