import SwiftUI

/// Full-screen recording UI: scrolling waveform, elapsed time,
/// pause/resume, stop.
struct RecordView: View {
    @StateObject private var recording = RecordingService()
    @Environment(\.dismiss) private var dismiss
    @State private var permissionDenied = false

    /// Called with the finished audio file when the user stops.
    let onFinished: (URL) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                Text(timeString(recording.duration))
                    .font(.system(size: 60, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.textPrimary)
                    .contentTransition(.numericText())

                statusLine
                    .padding(.top, 4)

                WaveformView(samples: recording.levelHistory,
                             isPaused: recording.isPaused,
                             isActive: recording.isRecording)
                    .frame(height: 160)
                    .padding(.horizontal, 24)
                    .padding(.top, 36)

                if let error = recording.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 16)
                }
                if permissionDenied {
                    Text("Ge Transcribe tillgång till mikrofonen i Inställningar → Integritet.")
                        .font(.callout)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 16)
                }

                Spacer()

                controls
                    .padding(.bottom, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surfaceBackground)
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

    private var statusLine: some View {
        Group {
            if recording.isPaused {
                Label("Pausad", systemImage: "pause.fill")
                    .foregroundStyle(.orange)
            } else if recording.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(0.6 + 0.4 * Double(recording.level))
                    Text("Spelar in")
                        .foregroundColor(.textSecondary)
                }
            } else {
                Text("Redo att spela in")
                    .foregroundColor(.textTertiary)
            }
        }
        .font(.subheadline)
    }

    private var controls: some View {
        HStack(spacing: 56) {
            if recording.isRecording {
                Button {
                    recording.isPaused ? recording.resume() : recording.pause()
                } label: {
                    Image(systemName: recording.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 60, height: 60)
                        .background(Color.elevatedSurface, in: Circle())
                        .foregroundColor(.textPrimary)
                }

                RecordButton(isRecording: true, level: recording.level) {
                    if let url = recording.stop() {
                        dismiss()
                        onFinished(url)
                    }
                }

                // Symmetry spacer matching the pause button
                Color.clear.frame(width: 60, height: 60)
            } else {
                RecordButton(isRecording: false, level: 0) {
                    Task {
                        if await recording.requestPermission() {
                            recording.start()
                        } else {
                            permissionDenied = true
                        }
                    }
                }
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// The big red button: idle it breathes softly; while recording a live
/// ring pulses with the input level and the glyph morphs to a stop square.
private struct RecordButton: View {
    let isRecording: Bool
    let level: Float
    let action: () -> Void

    @State private var breathe = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Level-driven halo
                Circle()
                    .fill(Color.red.opacity(isRecording ? 0.18 : 0.10))
                    .frame(width: haloSize, height: haloSize)
                    .animation(.easeOut(duration: 0.12), value: level)

                Circle()
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 2)
                    .frame(width: 86, height: 86)
                    .scaleEffect(breathe && !isRecording ? 1.06 : 1.0)

                if isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 34, height: 34)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 68, height: 68)
                }
            }
            .frame(width: 150, height: 150)
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    private var haloSize: CGFloat {
        isRecording ? 92 + CGFloat(level) * 56 : 100
    }
}

/// Scrolling mirrored-bar waveform in the brand gradient. New samples enter
/// from the right; history fades out to the left. Idle state shows a calm
/// dotted baseline.
private struct WaveformView: View {
    let samples: [Float]
    let isPaused: Bool
    let isActive: Bool

    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 2.5

    var body: some View {
        Canvas { context, size in
            let step = barWidth + gap
            let capacity = Int(size.width / step)
            let midY = size.height / 2

            guard isActive, !samples.isEmpty else {
                // Idle: dotted baseline
                for i in 0..<capacity {
                    let x = CGFloat(i) * step
                    let rect = CGRect(x: x, y: midY - 1.5, width: barWidth, height: 3)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(Color.textTertiary.opacity(0.25)))
                }
                return
            }

            let recent = Array(samples.suffix(capacity))
            let offset = capacity - recent.count
            for (i, sample) in recent.enumerated() {
                // Perceptual lift so quiet speech still moves the bars
                let value = CGFloat(pow(sample, 0.7))
                let height = max(3, value * (size.height - 8))
                let x = CGFloat(offset + i) * step
                let rect = CGRect(x: x, y: midY - height / 2,
                                  width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

                // Fade toward the old (left) edge
                let age = Double(i) / Double(max(1, recent.count - 1))
                let alpha = 0.25 + 0.75 * age
                let color = isPaused ? Color.orange : Color.primaryAccent
                context.fill(path, with: .color(color.opacity(alpha)))
            }
        }
        .drawingGroup()
    }
}
