import SwiftUI

struct AboutView: View {
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    private var preferredScheme: ColorScheme? {
        switch appColorScheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Transcribe")
                .font(.largeTitle)
                .bold()
                .foregroundColor(.textPrimary)

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.subheadline)
                .foregroundColor(.textSecondary)

            Text("Audio transcription for macOS")
                .font(.body)
                .foregroundColor(.textPrimary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                featureRow("Swedish & Norwegian with KB & NB Whisper")
                featureRow("Other languages with OpenAI Whisper")
                featureRow("Local & cloud LLM processing")
                featureRow("Privacy & sovereignty by design")
                featureRow("Built with Swift & SwiftUI")
            }

            Spacer()

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
                .padding(.bottom, 16)
        }
        .padding(24)
        .frame(width: 440, height: 520)
        .background(Color.surfaceBackground)
        .preferredColorScheme(preferredScheme)
    }

    func featureRow(_ text: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            Text(text)
                .font(.body)
                .foregroundColor(.textPrimary)
        }
    }
}
