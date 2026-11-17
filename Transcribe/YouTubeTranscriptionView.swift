import SwiftUI
import TranscribeKit

/// Sheet for transcribing a YouTube video: paste a link, the audio is
/// downloaded, and the file is handed to the transcription screen.
struct YouTubeTranscriptionView: View {
    @StateObject private var youtubeService = YouTubeDownloadService()
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @AppStorage("localOnlyMode") private var localOnlyMode = false
    @Environment(\.dismiss) private var dismiss

    @State private var youtubeURL = ""
    @State private var video: VideoSummary?
    @State private var stage: Stage = .idle
    @State private var processingTask: Task<Void, Never>?
    /// The download was passed to the transcription screen and must survive this sheet.
    @State private var handedOff = false
    @FocusState private var linkFieldFocused: Bool

    private enum Stage {
        case idle
        case fetchingInfo
        case downloading
        case startingTranscription
    }

    private struct VideoSummary {
        let title: String
        let thumbnailURL: URL?
        let duration: String?
    }

    private var isProcessing: Bool { stage != .idle }

    private var canStart: Bool {
        !isProcessing && !localOnlyMode
            && !youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            if let video {
                videoCard(video)
            } else {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.primaryAccent)
                    .frame(width: 68, height: 68)
                    .background(Color.primaryAccent.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
            }

            VStack(spacing: 6) {
                Text(localized("youtube_sheet_title"))
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(localized("youtube_sheet_hint"))
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
            }
            .multilineTextAlignment(.center)

            TextField(localized("youtube_paste_link"), text: $youtubeURL)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 440)
                .focused($linkFieldFocused)
                .disabled(isProcessing || localOnlyMode)
                .onSubmit(start)
                .accessibilityLabel(localized("youtube_paste_link"))

            status
                .frame(maxWidth: 440)
                .frame(minHeight: 44)

            actions

            Spacer(minLength: 0)
        }
        .padding(Metrics.gutter)
        .frame(width: 600, height: 500)
        // The palette's text colours are tuned for the app's own surface,
        // not for whatever material the system gives a sheet
        .background { AuroraBackdrop(intensity: 0.4) }
        .onAppear { linkFieldFocused = true }
        .onChange(of: youtubeURL) { _, _ in
            // What was fetched, or failed, belongs to the previous link
            guard !isProcessing else { return }
            video = nil
            youtubeService.errorMessage = nil
        }
        .onDisappear {
            processingTask?.cancel()
            if !handedOff {
                youtubeService.cleanup()
            }
        }
    }

    // MARK: - Pieces

    private func videoCard(_ video: VideoSummary) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: video.thumbnailURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Loading or missing: a still placeholder, not a spinner
                    // that would turn forever when there is no thumbnail
                    Color.elevatedSurface
                        .overlay(
                            Image(systemName: "play.rectangle")
                                .font(.title2)
                                .foregroundStyle(Color.textTertiary)
                        )
                }
            }
            .frame(width: 144, height: 81)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                if let duration = video.duration {
                    Label(duration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: 440)
        .contentCard()
    }

    @ViewBuilder
    private var status: some View {
        if localOnlyMode {
            Label(localized("youtube_local_only"), systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
        } else {
            switch stage {
            case .idle:
                if let error = youtubeService.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.recordingRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .fetchingInfo:
                working(localized("youtube_fetching_info"))
            case .downloading:
                VStack(spacing: 8) {
                    working(localized("youtube_downloading"), percent: Int(youtubeService.downloadProgress * 100))
                    ProgressView(value: youtubeService.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(.primaryAccent)
                        .accessibilityLabel(localized("youtube_downloading"))
                }
            case .startingTranscription:
                working(localized("youtube_starting_transcription"))
            }
        }
    }

    /// A line for work in progress, with a way to stop it without leaving the sheet.
    private func working(_ text: String, percent: Int? = nil) -> some View {
        HStack(spacing: 10) {
            AccentSpinner(size: 14, lineWidth: 2)
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: 8)
            if let percent {
                Text("\(percent) %")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.primaryAccent)
            }
            Button(action: cancelProcessing) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.textTertiary)
            }
            .buttonStyle(.plain)
            .help(localized(percent == nil ? "cancel" : "cancel_download"))
            .accessibilityLabel(localized(percent == nil ? "cancel" : "cancel_download"))
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: start) {
                Label(
                    youtubeService.errorMessage == nil ? localized("transcribe") : localized("youtube_try_again"),
                    systemImage: "waveform"
                )
                .frame(minWidth: 180)
            }
            .prominentAction()
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)

            // Esc, and always available: closing the sheet stops whatever is running
            Button(localized("cancel"), action: close)
                .glassAction()
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Actions

    private func start() {
        guard canStart else { return }
        // Set before the task runs: Return reaches both the field and the
        // default button, and the second call must find the sheet busy
        stage = .fetchingInfo
        youtubeService.errorMessage = nil

        let link = youtubeURL
        let previous = processingTask
        processingTask = Task {
            // A run that was just cancelled removes its partial file as it
            // unwinds; the same video would be written to the same path
            await previous?.value
            await process(link)
        }
    }

    private func process(_ link: String) async {
        // Cancelled while waiting: the sheet has already been reset
        guard !Task.isCancelled else { return }

        do {
            let info = try await youtubeService.fetchVideoInfo(from: link)
            try Task.checkCancellation()
            video = VideoSummary(title: info.title, thumbnailURL: info.thumbnailURL, duration: info.duration)

            stage = .downloading
            let fileURL = try await youtubeService.downloadVideoForTranscription(from: link)
            try Task.checkCancellation()

            // Long enough for "Starting transcription…" to be read
            stage = .startingTranscription
            try await Task.sleep(for: .milliseconds(500))

            handedOff = true
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowTranscriptionView"),
                object: nil,
                userInfo: ["fileURL": fileURL, "title": info.title]
            )
            dismiss()
        } catch {
            // Covers a cancel that arrived after the download had finished
            youtubeService.cleanup()
            // Whoever cancelled has already reset the sheet; the error a
            // cancelled request throws is not something to show
            guard !Task.isCancelled else { return }
            youtubeService.errorMessage = error.localizedDescription
            stage = .idle
        }
    }

    /// Stops the work in flight and returns to the link field.
    private func cancelProcessing() {
        processingTask?.cancel()
        stage = .idle
        video = nil
        youtubeService.errorMessage = nil
        linkFieldFocused = true
    }

    private func close() {
        cancelProcessing()
        dismiss()
    }
}

/// Linear progress bar in the accent gradient. This sheet no longer uses it;
/// the transcription screen does, so it has to stay defined.
struct LinearProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.borderLight.opacity(0.3))
                    .frame(height: 6)
                
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient.accentGradient)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0), height: 6)
                    .animation(.linear(duration: 0.2), value: configuration.fractionCompleted)
            }
        }
        .frame(height: 6)
    }
}

#Preview {
    YouTubeTranscriptionView()
}
