import SwiftUI

struct AboutView: View {
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)

            Text("Transcribe")
                .font(.largeTitle)
                .bold()

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Audio transcription for macOS")
                .font(.body)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                featureRow("Swedish, Norwegian & English with KB & NB Whisper")
                featureRow("Local & cloud LLM processing")
                featureRow("Privacy & sovereignty by design")
                featureRow("Built with Swift & SwiftUI")
            }

            Spacer()

            VStack(spacing: 6) {
                Text("Micke Kring, Peter Ljungstrand & Claude Code")
                    .font(.caption)
                Text("Open source under the MIT license")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Link("GitHub", destination: URL(string: "https://github.com/mickekring/Transcribe-MacOS-App")!)
                .font(.caption)
        }
        .padding()
        .frame(width: 440, height: 460)
    }

    func featureRow(_ text: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            Text(text)
                .font(.body)
        }
    }
}
