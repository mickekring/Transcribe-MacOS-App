import SwiftUI

/// Full-screen recording UI: level meter, elapsed time, pause/resume, stop.
struct RecordView: View {
    @StateObject private var recording = RecordingService()
    @Environment(\.dismiss) private var dismiss
    @State private var permissionDenied = false

    /// Called with the finished audio file when the user stops.
    let onFinished: (URL) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Text(timeString(recording.duration))
                    .font(.system(size: 56, weight: .light, design: .monospaced))
                    .contentTransition(.numericText())

                levelMeter

                if let error = recording.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                if permissionDenied {
                    Text("Ge Transcribe tillgång till mikrofonen i Inställningar → Integritet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                HStack(spacing: 48) {
                    if recording.isRecording {
                        Button {
                            recording.isPaused ? recording.resume() : recording.pause()
                        } label: {
                            Image(systemName: recording.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                .font(.system(size: 56))
                        }
                        .tint(.orange)

                        Button {
                            if let url = recording.stop() {
                                dismiss()
                                onFinished(url)
                            }
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 72))
                        }
                        .tint(.red)
                    } else {
                        Button {
                            Task {
                                if await recording.requestPermission() {
                                    recording.start()
                                } else {
                                    permissionDenied = true
                                }
                            }
                        } label: {
                            Image(systemName: "record.circle")
                                .font(.system(size: 72))
                        }
                        .tint(.red)
                    }
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("Spela in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Avbryt") {
                        recording.discard()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(recording.isRecording)
        }
    }

    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(recording.isPaused ? Color.orange : Color.green)
                    .frame(width: geo.size.width * CGFloat(recording.level))
                    .animation(.linear(duration: 0.1), value: recording.level)
            }
        }
        .frame(height: 10)
        .padding(.horizontal, 40)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
