import SwiftUI
import TranscribeKit

/// iOS counterpart of the Mac app's About window — same content and tone.
struct AboutView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.accentGradient)
                        .frame(width: 84, height: 84)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundColor(.black)
                }
                .shadow(color: Color.primaryAccent.opacity(0.35), radius: 16, y: 4)
                .padding(.top, 24)

                Text("Transcribe")
                    .font(.largeTitle.bold())
                    .foregroundColor(.textPrimary)

                Text(String(format: localized("ios_version"), appVersion, buildNumber))
                    .font(.subheadline)
                    .foregroundColor(.textSecondary)

                Divider()
                    .padding(.horizontal, 40)

                VStack(alignment: .leading, spacing: 10) {
                    featureRow("Swedish & Norwegian with KB & NB Whisper")
                    featureRow("Other languages with Whisper")
                    featureRow("On-device speaker identification")
                    featureRow("Privacy & sovereignty by design")
                    featureRow("Built with Swift & SwiftUI")
                }
                .padding(.horizontal, 32)

                Spacer(minLength: 24)

                VStack(spacing: 6) {
                    Text("Micke Kring, Peter Ljungstrand & Claude Code")
                        .font(.caption)
                        .foregroundColor(.textPrimary)
                    Text("Open source under the MIT license")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                }

                Link("GitHub", destination: URL(string: "https://github.com/mickekring/Transcribe-MacOS-App")!)
                    .font(.caption)
                    .foregroundColor(.primaryAccent)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.surfaceBackground)
        .navigationTitle(localized("ios_about"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func featureRow(_ text: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.primaryAccent)
                .font(.caption)
            Text(text)
                .font(.callout)
                .foregroundColor(.textPrimary)
        }
    }
}
