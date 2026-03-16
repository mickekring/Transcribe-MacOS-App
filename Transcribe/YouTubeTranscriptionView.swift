import SwiftUI

struct YouTubeTranscriptionView: View {
    @State private var youtubeURL = ""
    @State private var isProcessing = false
    @State private var showingVideoInfo = false
    @State private var videoTitle: String?
    @State private var thumbnailURL: URL?
    @State private var videoDuration: String?
    @State private var downloadComplete = false
    
    @StateObject private var youtubeService = YouTubeDownloadService()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.surfaceBackground
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                headerSection
                
                if !showingVideoInfo {
                    // URL Input Section
                    urlInputSection
                } else {
                    // Video Info & Download Section
                    videoInfoSection
                }
            }
            .frame(width: 600, height: 500)
        }
    }
    
    var headerSection: some View {
        HStack {
            Button(action: {
                if showingVideoInfo && !isProcessing {
                    showingVideoInfo = false
                    youtubeURL = ""
                    videoTitle = nil
                    thumbnailURL = nil
                } else if !isProcessing {
                    dismiss()
                }
            }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.textSecondary)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("YouTube Transkribering")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.textPrimary)
            
            Spacer()
            
            // Placeholder for balance
            Color.clear
                .frame(width: 30, height: 30)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.surfaceBackground)
        .overlay(
            Rectangle()
                .fill(Color.borderLight)
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    var urlInputSection: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 24) {
                // YouTube Icon
                ZStack {
                    Circle()
                        .fill(Color.primaryAccent.opacity(0.12))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                
                Text("Klistra in YouTube-länk")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.textPrimary)
                
                Text("Videon laddas ner i lägsta kvalitet för snabb transkribering")
                    .font(.system(size: 14))
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            
            // URL Input Field
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://youtube.com/watch?v=...", text: $youtubeURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(14)
                    .background(Color.cardBackground)
                    .cornerRadius(12)
                    .foregroundColor(.textPrimary)
                    .disabled(isProcessing)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.borderLight, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 60)
            
            // Transcribe Button
            Button(action: {
                Task {
                    await fetchVideoInfo()
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    } else {
                        Text("Transkribera")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundColor(.textPrimary)
                .frame(width: 180, height: 44)
                .background(Color.cardBackground)
                .cornerRadius(22)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.borderLight, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(youtubeURL.isEmpty || isProcessing)
            
            if let error = youtubeService.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.horizontal, 60)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
    }
    
    var videoInfoSection: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Video Thumbnail & Info
            VStack(spacing: 20) {
                // Thumbnail
                if let thumbnailURL = thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 400, maxHeight: 225)
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.cardBackground)
                            .frame(width: 400, height: 225)
                            .overlay(
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            )
                    }
                }
                
                // Title
                if let title = videoTitle {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 40)
                }
                
                // Duration
                if let duration = videoDuration {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                        Text(duration)
                            .font(.system(size: 14))
                    }
                    .foregroundColor(.textSecondary)
                }
            }
            
            // Download Progress
            if isProcessing {
                VStack(spacing: 12) {
                    HStack {
                        Text(downloadComplete ? "Startar transkribering..." : "Laddar ner video...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.textPrimary)
                        
                        Spacer()
                        
                        if !downloadComplete {
                            Text("\(Int(youtubeService.downloadProgress * 100))%")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.textPrimary)
                        }
                    }
                    
                    ProgressView(value: youtubeService.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .tint(Color.primaryAccent)
                        .accentColor(Color.primaryAccent)
                        .background(Color.borderLight.opacity(0.2))
                        .cornerRadius(4)
                        .frame(height: 6)
                }
                .padding(.horizontal, 60)
            }
            
            Spacer()
        }
    }
    
    private func fetchVideoInfo() async {
        isProcessing = true
        youtubeService.errorMessage = nil
        
        do {
            // Fetch video info
            let info = try await youtubeService.fetchVideoInfo(from: youtubeURL)
            
            await MainActor.run {
                self.videoTitle = info.title
                self.thumbnailURL = info.thumbnailURL
                self.videoDuration = info.duration
                self.showingVideoInfo = true
            }
            
            // Start download automatically
            await downloadAndTranscribe()
            
        } catch {
            await MainActor.run {
                youtubeService.errorMessage = error.localizedDescription
                isProcessing = false
            }
        }
    }
    
    private func downloadAndTranscribe() async {
        do {
            // Download video
            let localFileURL = try await youtubeService.downloadVideoForTranscription(from: youtubeURL)
            
            await MainActor.run {
                downloadComplete = true
            }
            
            // Small delay for UI feedback
            try await Task.sleep(nanoseconds: 500_000_000)
            
            // Start transcription automatically
            await MainActor.run {
                // Dismiss this view and show transcription with the downloaded file
                NotificationCenter.default.post(
                    name: NSNotification.Name("ShowTranscriptionView"),
                    object: nil,
                    userInfo: ["fileURL": localFileURL, "title": videoTitle ?? "YouTube Video"]
                )
                
                dismiss()
            }
            
        } catch {
            await MainActor.run {
                youtubeService.errorMessage = error.localizedDescription
                isProcessing = false
                downloadComplete = false
            }
        }
    }
}

// Linear Progress Style
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