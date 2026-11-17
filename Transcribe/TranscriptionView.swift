import SwiftUI
import TranscribeKit
import AVFoundation
import UniformTypeIdentifiers

// Custom button style with press animation
struct TranscriptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

private extension Color {
    /// Outline of a disabled outlined button. Derived from the tertiary text
    /// colour its label uses, so it adapts to the theme — a faint white
    /// outline is invisible on the light surface.
    static let disabledOutline = Color.textTertiary.opacity(0.3)
}

struct TranscriptionView: View {
    @StateObject private var viewModel: TranscriptionViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var bergetCatalog = BergetModelCatalog.shared
    @State private var showingExportPopover = false
    @State private var displayMode: DisplayMode = .transcript
    @State private var fontSize: Double = 16
    @State private var showUnsavedChangesAlert = false
    @State private var hasBeenEdited = false
    @State private var selectedPromptId: UUID? = nil
    @State private var additionalPromptInfo: String = ""
    @State private var showAdditionalInfoSheet = false
    @State private var additionalInfoDraft: String = ""
    @State private var showPromptPopover = false
    @State private var showLLMPopover = false
    @State private var isProcessingLLM = false
    @State private var llmTask: Task<Void, Never>? = nil
    
    enum DisplayMode {
        case transcript
        case segments
        case timestamps
        case speakers
    }
    
    init(fileURL: URL) {
        _viewModel = StateObject(wrappedValue: TranscriptionViewModel(fileURL: fileURL))
    }
    
    var body: some View {
        GeometryReader { geometry in
            let leadingInset: CGFloat = 20
            let availableWidth = geometry.size.width - leadingInset
            HStack(spacing: 40) {
                // Left side - Transcription (66%)
                transcriptionSection
                    .frame(width: availableWidth * 0.66)
                
                // Right side - Controls and Audio Player (30%)
                rightSidePanel
                    .frame(width: availableWidth * 0.30)
            }
            .padding(.leading, leadingInset)
        }
        .background(Color.surfaceBackground)
        .navigationTitle(viewModel.fileName)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BackToolbarButton {
                    switch unsavedWork {
                    case .unsavedTranscript:
                        showUnsavedChangesAlert = true
                    case .some:
                        // A recording not yet transcribed: the app-wide
                        // "leave?" confirmation
                        appState.navigate(to: .home)
                    case nil:
                        dismissView()
                    }
                }
            }
        }
        // Tell the app, so quitting, closing the window or a route change from
        // outside this view (status-bar menu) also asks before work is lost
        .onChange(of: unsavedWork, initial: true) { _, unsaved in
            appState.unsavedWork = unsaved
        }
        // Text processing or renamed speakers after a save make it unsaved again
        .onChange(of: viewModel.processedText) { _, text in
            if !text.isEmpty { viewModel.markUnsaved() }
        }
        .onChange(of: viewModel.speakerNames) { _, _ in
            viewModel.markUnsaved()
        }
        .alert(localized("unsaved_transcription"), isPresented: $showUnsavedChangesAlert) {
            Button(localized("copy_and_go_back"), role: nil) {
                viewModel.copyToClipboard(exportableTranscript)
                dismissView()
            }
            Button(localized("go_back_without_saving"), role: nil) {
                dismissView()
            }
            Button(localized("cancel"), role: .cancel) { }
        } message: {
            Text(localized("unsaved_transcription_message"))
        }
        .alert(localized("export_error"), isPresented: $viewModel.showExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.exportErrorMessage)
        }
        .onAppear {
            viewModel.startTranscription()
            // Pre-fetch Ollama models so the LLM dropdown has data
            Task {
                await settingsManager.checkOllamaConnection()
            }
        }
        .onDisappear {
            // Covers window close and view replacement (.id change) as well as back navigation
            cancelLLMProcessing()
            viewModel.cancelActiveWork()
        }
        .onChange(of: settingsManager.textProcessingPrompts) { _, prompts in
            // A prompt deleted in Settings can no longer be run, so it must
            // not stay selected
            if let id = selectedPromptId, !prompts.contains(where: { $0.id == id }) {
                selectedPromptId = nil
            }
        }
    }

    /// A finished transcript that has been neither saved nor copied.
    private var hasUnsavedTranscript: Bool {
        !viewModel.transcribedText.isEmpty && !viewModel.isTranscribing && !viewModel.hasExported
    }

    /// What leaving or quitting would lose: an unsaved transcript, or a
    /// recording made in the app that is not transcribed yet (still running,
    /// failed or cancelled). It lives only in the temp folder.
    private var unsavedWork: AppState.UnsavedWork? {
        if hasUnsavedTranscript { return .unsavedTranscript }
        if AppState.isAppRecording(viewModel.fileURL),
           viewModel.isTranscribing || viewModel.transcribedText.isEmpty {
            return .untranscribedRecording
        }
        return nil
    }

    /// Cancels all in-flight work and navigates back to the main view.
    private func dismissView() {
        cancelLLMProcessing()
        viewModel.cancelActiveWork()
        appState.closeTranscriptionView()
    }

    /// Stops a running LLM request, keeping what it has produced so far.
    /// The cancelled task leaves view state alone afterwards (a new request
    /// may already be running), so the flag is reset here.
    private func cancelLLMProcessing() {
        llmTask?.cancel()
        llmTask = nil
        isProcessingLLM = false
    }

    /// Runs the transcription again. The LLM output describes the transcript
    /// being replaced, so its request is stopped first; the view model clears
    /// the processed text and the speaker turns.
    private func restartTranscription() {
        cancelLLMProcessing()
        viewModel.retranscribe()
    }
    
    private var transcriptionHeader: some View {
        HStack {
            Text(localized("transcription"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.textPrimary)
            
            Spacer()
            
            if viewModel.isTranscribing {
                AccentSpinner(size: 16, lineWidth: 2)
            }
            
            transcriptionStats
        }
        .padding()
        .background(Color.surfaceBackground)
    }
    
    private var transcriptionStats: some View {
        HStack(spacing: 16) {
            if viewModel.duration > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(localized("duration"))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                    Text(formatTime(viewModel.duration))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
            }
            
            if viewModel.transcriptionTime > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(localized("transcription_time"))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                    Text(formatTime(viewModel.transcriptionTime))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
            }
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(localized("words"))
                    .font(.system(size: 10))
                    .foregroundColor(.textTertiary)
                Text("\(viewModel.wordCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textSecondary)
            }
            
            if viewModel.wordCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(localized("tokens"))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                    Text("\(viewModel.estimatedTokenCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }
    
    /// Status message renderer: the first line (e.g. "Anpassar X (41 s)") is
    /// prominent; anything after a newline is secondary explanation text.
    @ViewBuilder
    private func statusMessageText(_ message: String) -> some View {
        let parts = message.split(separator: "\n", maxSplits: 1).map(String.init)
        VStack(spacing: 8) {
            Text(parts.first ?? "")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.textPrimary)
                .monospacedDigit()
            if parts.count > 1 {
                Text(parts[1])
                    .font(.system(size: 12))
                    .foregroundColor(.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
    }

    private var streamingIndicator: some View {
        HStack {
            HStack(spacing: 10) {
                AccentSpinner(size: 16, lineWidth: 2)
                Text(localized("transcribing"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.borderLight, lineWidth: 0.5)
            )
            
            Spacer()
        }
        .padding(.leading, 16)
        .padding(.bottom, 16)
    }
    
    private var processingIndicator: some View {
        HStack {
            HStack(spacing: 10) {
                AccentSpinner(size: 16, lineWidth: 2)
                Text(localized("processing_with_llm"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.borderLight, lineWidth: 0.5)
            )
            
            Spacer()
        }
        .padding(.leading, 16)
        .padding(.bottom, 16)
    }
    
    private var transcriptionContent: some View {
        Group {
            if !viewModel.transcribedText.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // A failed run keeps what it had transcribed; the error
                    // sits above the partial transcript instead of replacing it
                    if viewModel.errorMessage != nil {
                        transcriptionErrorCard
                            .padding([.horizontal, .top], 16)
                    }

                    let displayText: String = {
                        // Speakers mode shows status until diarization has produced turns
                        // (not while a run is streaming or after one failed — see
                        // speakerTextPending)
                        if speakerTextPending {
                            if viewModel.segments.isEmpty {
                                return localized("speakers_unavailable")
                            }
                            if let error = viewModel.diarizationError {
                                return localized("diarization_failed") + "\n\(error)"
                            }
                            return localized("diarizing") + " \(Int(viewModel.diarizationProgress * 100))%"
                        }
                        return exportableTranscript
                    }()
                    
                    AutoScrollingTextView(
                        text: displayText,
                        fontSize: fontSize,
                        isStreaming: viewModel.isTranscribing
                    )
                    // Overlay instead of stacking below: stays visible even
                    // when a short window would push a stacked pill offscreen
                    .overlay(alignment: .bottomLeading) {
                        if viewModel.isTranscribing {
                            streamingIndicator
                        }
                    }
                }
            } else if viewModel.isTranscribing || !viewModel.hasStartedRun {
                // Also before the first run starts (it does in onAppear):
                // there is no outcome to report yet
                transcriptionProgressView
            } else {
                // The run is over and left no text: say why instead of
                // spinning forever
                transcriptionEndedView
            }
        }
    }

    /// Takes the progress card's place once a run has ended without any text:
    /// the error if it failed, otherwise whether it was cancelled or simply
    /// found no speech — each with a way to run it again.
    private var transcriptionEndedView: some View {
        VStack {
            Spacer()

            if viewModel.errorMessage != nil {
                transcriptionErrorCard
                    .frame(maxWidth: 560)
            } else {
                VStack(spacing: 24) {
                    Image(systemName: viewModel.wasCancelled ? "xmark.circle" : "waveform.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.textTertiary)

                    statusMessageText(localized(viewModel.wasCancelled ? "transcription_cancelled" : "no_speech_detected"))

                    retranscribeButton
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.borderLight, lineWidth: 0.5)
                )
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceBackground)
    }

    /// Why the last run failed, and a way to retry. The title depends on
    /// whether anything was transcribed before the failure.
    private var transcriptionErrorCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(localized(viewModel.transcribedText.isEmpty ? "transcription_failed" : "transcription_incomplete"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textPrimary)
                Text(viewModel.errorMessage ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(.textSecondary)
                    .textSelection(.enabled)
                Text("\(localized("model")): \(modelManager.displayName(for: viewModel.activeModelId))")
                    .font(.system(size: 12))
                    .foregroundColor(.textTertiary)
                Text(localized(ModelManager.engine(for: viewModel.activeModelId) == .cloud
                               ? "transcription_error_hint_cloud"
                               : "transcription_error_hint_local"))
                    .font(.system(size: 12))
                    .foregroundColor(.textTertiary)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            retranscribeButton
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.borderLight, lineWidth: 0.5)
        )
    }

    /// The way out of the error, cancelled and no-speech states. Styled like
    /// the side panel's outlined buttons.
    private var retranscribeButton: some View {
        Button(action: { restartTranscription() }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.trianglehead.2.counterclockwise")
                    .font(.system(size: 13))
                Text(localized("retranscribe"))
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundColor(.textPrimary)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Metrics.controlRadius))
        }
        .buttonStyle(TranscriptionButtonStyle())
        .fixedSize()
    }
    
    private var processedTextContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownTextView(
                markdown: viewModel.processedText,
                fontSize: fontSize,
                isStreaming: isProcessingLLM
            )
            
            if isProcessingLLM {
                processingIndicator
            }
        }
    }
    
    private var showProcessedPanel: Bool {
        !viewModel.processedText.isEmpty || isProcessingLLM
    }
    
    var transcriptionSection: some View {
        VStack(spacing: 0) {
            transcriptionHeader
            
            if !viewModel.transcribedText.isEmpty {
                if showProcessedPanel {
                    // Split view: transcription left, processed text right
                    HStack(spacing: 0) {
                        transcriptionContent
                            .background(Color.surfaceBackground)
                        
                        // Vertical divider
                        Rectangle()
                            .fill(Color.borderLight)
                            .frame(width: 1)
                            .padding(.vertical, 12)
                        
                        processedTextContent
                            .background(Color.surfaceBackground)
                    }
                } else {
                    // Full width transcription
                    transcriptionContent
                        .background(Color.surfaceBackground)
                }
            } else {
                ScrollView {
                    transcriptionContent
                }
                .background(Color.surfaceBackground)
            }
        }
    }
    
    /// The model this run needs, while it is being downloaded. Other models
    /// can be downloading at the same time (started from Settings); their
    /// progress says nothing about this run.
    private var activeDownloadModelId: String? {
        let modelId = viewModel.activeModelId
        return modelManager.isDownloading[modelId] == true ? modelId : nil
    }
    
    private var transcriptionProgressView: some View {
        VStack {
            Spacer()
            
            // Progress card with rounded corners and shadow
            VStack(spacing: 24) {
                if let downloadingId = activeDownloadModelId {
                    // Model download in progress — show download progress
                    let progress = modelManager.downloadProgress[downloadingId] ?? 0
                    let speed = modelManager.downloadSpeed[downloadingId] ?? 0
                    let totalBytes = modelManager.modelSizeBytes(for: downloadingId) ?? 0
                    let downloadedBytes = Int64(progress * Double(totalBytes))
                    
                    AccentSpinner(size: 32, lineWidth: 3)
                    
                    Text(String(format: localized("downloading_model"), modelManager.displayName(for: downloadingId)))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                    
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .tint(Color.primaryAccent)
                        .frame(width: 260)
                        .scaleEffect(y: 2)
                    
                    HStack {
                        Text(String(format: localized("download_progress"),
                                    formattedBytes(downloadedBytes),
                                    formattedBytes(totalBytes)))
                            .font(.system(size: 12))
                            .foregroundColor(.textSecondary)
                        
                        if speed > 0 {
                            Text("·")
                                .foregroundColor(.textTertiary)
                            Text(formattedSpeed(speed))
                                .font(.system(size: 12))
                                .foregroundColor(.textSecondary)
                        }
                    }
                    .monospacedDigit()
                    
                } else if viewModel.isPreprocessing {
                    // Show spinner for preprocessing
                    AccentSpinner(size: 32, lineWidth: 3)
                    
                    statusMessageText(viewModel.statusMessage.isEmpty ? localized("preparing_audio_file") : viewModel.statusMessage)
                } else if viewModel.isProcessingChunks {
                    // Show progress bar for chunk transcription (stay visible between chunks)
                    VStack(spacing: 16) {
                        Text(String(format: localized("chunk_of"), viewModel.currentChunk, viewModel.totalChunks))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.textSecondary)
                        
                        ProgressView(value: viewModel.chunkProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .tint(Color.primaryAccent)
                            .frame(width: 260)
                            .scaleEffect(y: 2)
                    }
                    
                    statusMessageText(viewModel.statusMessage.isEmpty ? localized("preparing_audio_file") : viewModel.statusMessage)
                } else if viewModel.showSingleFileProgress {
                    // Show progress bar for single file transcription; the
                    // status is rendered once, below the bar like in the
                    // other branches
                    ProgressView(value: viewModel.singleFileProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .tint(Color.primaryAccent)
                        .frame(width: 260)
                        .scaleEffect(y: 2)
                        
                    statusMessageText(viewModel.statusMessage.isEmpty ? localized("transcribing") : viewModel.statusMessage)
                } else {
                    AccentSpinner(size: 32, lineWidth: 3)
                    
                    statusMessageText(viewModel.statusMessage.isEmpty ? localized("preparing_audio_file") : viewModel.statusMessage)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.borderLight, lineWidth: 0.5)
            )
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceBackground)
    }
    
    var rightSidePanel: some View {
        GlassEffectContainer {
        VStack(spacing: 0) {
            
            // Main content area — scrolls when the window is short
            // (e.g. many speaker rename fields in the Talare panel)
            ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                // Display Mode Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("display_mode"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 20)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        displayModeButton(.transcript, icon: "line.3.horizontal", labelKey: "transcript")
                        displayModeButton(.segments, icon: "text.alignleft", labelKey: "segments")
                        displayModeButton(.timestamps, icon: "clock", labelKey: "timestamps")
                        displayModeButton(.speakers, icon: "person.2", labelKey: "speakers")
                    }
                    .padding(.horizontal, 20)

                    if displayMode == .speakers {
                        speakerOptionsPanel
                            .padding(.horizontal, 20)
                    }
                }
                
                // Save/Copy Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("save_copy"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 20)
                    
                    HStack(spacing: 8) {
                        // Export button with custom dropdown
                        Button(action: { showingExportPopover.toggle() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 13))
                                Text(localized("save_as"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(exportDisabled ? .textTertiary : .textPrimary)
                            .contentShape(Rectangle())
                            .glassEffect(.regular.interactive(!exportDisabled), in: .rect(cornerRadius: Metrics.controlRadius))
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(exportDisabled)
                        .popover(isPresented: $showingExportPopover) {
                            VStack(alignment: .leading, spacing: 0) {
                                exportPopoverButton(
                                    icon: "doc.text",
                                    label: String(format: localized("export_as_txt"), localized(exportModeLabelKey)),
                                    enabled: !viewModel.transcribedText.isEmpty
                                ) {
                                    viewModel.exportText(exportableTranscript, suffix: exportModeSuffix)
                                    showingExportPopover = false
                                }

                                exportPopoverButton(
                                    icon: "doc.richtext",
                                    label: String(format: localized("export_as_md"), localized(exportModeLabelKey)),
                                    enabled: !viewModel.transcribedText.isEmpty
                                ) {
                                    viewModel.exportMarkdown(exportableTranscript, suffix: exportModeSuffix)
                                    showingExportPopover = false
                                }
                                
                                if !viewModel.processedText.isEmpty {
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    exportPopoverButton(
                                        icon: "doc.text",
                                        label: localized("export_processed_txt"),
                                        enabled: true
                                    ) {
                                        viewModel.exportProcessedAsText()
                                        showingExportPopover = false
                                    }
                                    
                                    exportPopoverButton(
                                        icon: "doc.richtext",
                                        label: localized("export_processed_md"),
                                        enabled: true
                                    ) {
                                        viewModel.exportProcessedAsMarkdown()
                                        showingExportPopover = false
                                    }
                                }
                            }
                            .frame(width: 260)
                            .padding(.vertical, 8)
                        }
                        
                        // Copy button
                        Button(action: { viewModel.copyToClipboard(exportableTranscript) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13))
                                Text(localized("copy_text"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(exportDisabled ? .textTertiary : .textPrimary)
                            .contentShape(Rectangle())
                            .glassEffect(.regular.interactive(!exportDisabled), in: .rect(cornerRadius: Metrics.controlRadius))
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(exportDisabled)
                    }
                    .padding(.horizontal, 20)
                }
                
                // Options Section
                VStack(alignment: .leading, spacing: 12) {
                    Text(localized("options"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 20)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        // Font Size Slider
                        VStack(alignment: .leading, spacing: 8) {
                            Text(localized("font_size"))
                                .font(.system(size: 12))
                                .foregroundColor(.textSecondary)
                            
                            HStack(spacing: 12) {
                                Text("A")
                                    .font(.system(size: 11))
                                    .foregroundColor(.textTertiary)
                                
                                ZStack {
                                    // Background track
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(height: 6)
                                    
                                    Slider(value: $fontSize, in: 14...24, step: 2)
                                        .tint(.primaryAccent)
                                }
                                
                                Text("A")
                                    .font(.system(size: 24))
                                    .foregroundColor(.textTertiary)
                            }
                        }

                    }
                    .padding(.horizontal, 20)
                }
                
                // Re-transcribe Section
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: { restartTranscription() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                .font(.system(size: 13))
                            Text(localized("retranscribe"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(viewModel.isTranscribing ? .textTertiary : .textPrimary)
                        .contentShape(Rectangle())
                        .glassEffect(.regular.interactive(!viewModel.isTranscribing), in: .rect(cornerRadius: Metrics.controlRadius))
                    }
                    .buttonStyle(TranscriptionButtonStyle())
                    .disabled(viewModel.isTranscribing)
                    .padding(.horizontal, 20)
                }
                
                // Process Transcription Section
                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("process_transcription"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 8) {
                        // Prompt picker (Button + popover, matching toolbar dropdown style)
                        Button(action: { showPromptPopover.toggle() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 13))
                                Text(selectedPromptName)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(sectionDisabled ? .textTertiary : .textPrimary)
                            .contentShape(Rectangle())
                            .glassEffect(.regular.interactive(!sectionDisabled), in: .rect(cornerRadius: Metrics.controlRadius))
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(sectionDisabled)
                        .popover(isPresented: $showPromptPopover) {
                            VStack(alignment: .leading, spacing: 0) {
                                promptPopoverRow(
                                    name: localized("select_prompt"),
                                    isSelected: selectedPromptId == nil
                                ) {
                                    selectedPromptId = nil
                                    showPromptPopover = false
                                }
                                
                                Divider().padding(.horizontal, 12).padding(.vertical, 4)
                                
                                ForEach(settingsManager.textProcessingPrompts) { prompt in
                                    promptPopoverRow(
                                        name: prompt.name,
                                        isSelected: selectedPromptId == prompt.id
                                    ) {
                                        selectedPromptId = prompt.id
                                        showPromptPopover = false
                                    }
                                }
                            }
                            .frame(width: 200)
                            .padding(.vertical, 8)
                        }
                        
                        // Additional info button
                        Button(action: {
                            additionalInfoDraft = additionalPromptInfo
                            showAdditionalInfoSheet = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: additionalPromptInfo.isEmpty ? "plus.circle" : "pencil.circle")
                                    .font(.system(size: 13))
                                Text(localized(additionalPromptInfo.isEmpty ? "add_information" : "edit_information"))
                                    .font(.system(size: 12, weight: .medium))
                                if !additionalPromptInfo.isEmpty {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.primaryAccent)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(sectionDisabled ? .textTertiary : .textPrimary)
                            .contentShape(Rectangle())
                            .glassEffect(.regular.interactive(!sectionDisabled), in: .rect(cornerRadius: Metrics.controlRadius))
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(sectionDisabled)
                        
                        // LLM model picker
                        Button(action: { showLLMPopover.toggle() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 13))
                                Text(selectedLLMDisplayName)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(sectionDisabled ? .textTertiary : .textPrimary)
                            .contentShape(Rectangle())
                            .glassEffect(.regular.interactive(!sectionDisabled), in: .rect(cornerRadius: Metrics.controlRadius))
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(sectionDisabled)
                        .popover(isPresented: $showLLMPopover) {
                            llmModelPopover
                        }
                        
                        // Process button — the way to stop the request
                        // while one is streaming
                        Button(action: {
                            if isProcessingLLM {
                                cancelLLMProcessing()
                            } else {
                                processTranscription()
                            }
                        }) {
                            HStack(spacing: 6) {
                                if isProcessingLLM {
                                    AccentSpinner(size: 13, lineWidth: 1.5)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 13))
                                }
                                Text(isProcessingLLM ? localized("cancel") : localized("process"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(processButtonDisabled ? .textTertiary : .textPrimary)
                            .contentShape(Rectangle())
                            .glassEffect(.regular.interactive(!processButtonDisabled), in: .rect(cornerRadius: Metrics.controlRadius))
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(processButtonDisabled)
                    }
                    .padding(.horizontal, 20)
                }
                .sheet(isPresented: $showAdditionalInfoSheet) {
                    additionalInfoSheet
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
            // Opaque cover over the toolbar band — the top-side twin of the
            // solid block under the audio player. The zero-height inset's
            // background stretches up through the safe area, so scrolled
            // content disappears behind the floating toolbar chips instead
            // of showing through between them.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .background(Color.surfaceBackground.ignoresSafeArea(edges: .top))
            }
            .background(Color.surfaceBackground)

            // Audio player pinned at the bottom, outside the scroll area
            audioPlayerSection
        }
        .background(Color.surfaceBackground)
        }
    }
    
    var audioPlayerSection: some View {
        VStack(spacing: 8) {
            if viewModel.duration > 0 {
                playbackControls
            } else {
                // Player setup failed (e.g. video containers) — hide controls instead of
                // rendering a Slider with an invalid 0...0 range
                Text(localized("playback_unavailable"))
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // File info
            HStack(spacing: 12) {
                Text(viewModel.fileName)
                    .font(.system(size: 10))
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)
                Spacer()
                Text(viewModel.fileFormat)
                    .font(.system(size: 10))
                    .foregroundColor(.textTertiary)
                Button(action: { viewModel.saveAudioFile() }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                .buttonStyle(.plain)
                .help(localized("save_audio_file"))
                .accessibilityLabel(localized("save_audio_file"))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    var playbackControls: some View {
        VStack(spacing: 8) {
            // Playback controls row
            HStack(spacing: 16) {
                Button(action: { viewModel.skipBackward() }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 18))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                .buttonStyle(.plain)
                .help(localized("skip_back_10"))
                .accessibilityLabel(localized("skip_back_10"))
                
                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                .buttonStyle(.plain)
                .help(localized(viewModel.isPlaying ? "pause" : "play"))
                .accessibilityLabel(localized(viewModel.isPlaying ? "pause" : "play"))
                
                Button(action: { viewModel.skipForward() }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 18))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                .buttonStyle(.plain)
                .help(localized("skip_forward_10"))
                .accessibilityLabel(localized("skip_forward_10"))
                
                // Speed dropdown
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button(action: { viewModel.playbackSpeed = speed }) {
                            if viewModel.playbackSpeed == speed {
                                Label("\(speed, specifier: "%.2g")x", systemImage: "checkmark")
                            } else {
                                Text("\(speed, specifier: "%.2g")x")
                            }
                        }
                    }
                } label: {
                    Text("\(viewModel.playbackSpeed, specifier: "%.2g")x")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.elevatedSurface)
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            
            // Time slider
            VStack(spacing: 2) {
                Slider(value: $viewModel.currentTime, in: 0...max(viewModel.duration, 0.01)) { editing in
                    viewModel.isScrubbing = editing
                    if !editing {
                        viewModel.seek(to: viewModel.currentTime)
                    }
                }
                .tint(.primaryAccent)

                HStack {
                    Text(formatTime(viewModel.currentTime))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                    Spacer()
                    Text(formatTime(viewModel.duration))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                }
            }
        }
    }
    
    func formatTime(_ time: Double) -> String {
        TranscriptionViewLogic.formatTime(time)
    }
    
    func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func formattedSpeed(_ bytesPerSec: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytesPerSec)) + "/s"
    }
    
    /// Speaker options shown while the Talare mode is active: a known-speaker-
    /// count picker (pins clustering, big win on short clips) and rename fields
    /// for each detected speaker. Names flow into display, save, and copy.
    private var speakerOptionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.isCloudDiarization {
            HStack {
                Text(localized("speaker_count"))
                    .font(.system(size: 12))
                    .foregroundColor(.textSecondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { viewModel.speakerCountHint ?? 0 },
                    set: { viewModel.rediarize(speakerCount: $0 == 0 ? nil : $0) }
                )) {
                    Text(localized("speaker_count_auto")).tag(0)
                    ForEach(2...8, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
                .disabled(viewModel.isDiarizing)
            }
            }

            if !viewModel.detectedSpeakerIds.isEmpty {
                ForEach(viewModel.detectedSpeakerIds, id: \.self) { speakerId in
                    HStack(spacing: 8) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.primaryAccent)
                        TextField(
                            String(format: localized("speaker_label"), speakerId + 1),
                            text: Binding(
                                get: { viewModel.speakerNames[speakerId] ?? "" },
                                set: { viewModel.speakerNames[speakerId] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cardBackground)
        )
    }

    private func displayModeButton(_ mode: DisplayMode, icon: String, labelKey: String) -> some View {
        Button(action: {
            displayMode = mode
            // Starts diarization now if the run has finished, otherwise as
            // soon as it does
            viewModel.setSpeakersModeActive(mode == .speakers)
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(localized(labelKey))
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // The label sits on the accent tint when selected
            .foregroundColor(displayMode == mode ? .onAccent : .textPrimary)
            .contentShape(Rectangle())
            .glassEffect(
                displayMode == mode ? .regular.tint(Color.primaryAccent).interactive() : .regular.interactive(),
                in: .rect(cornerRadius: Metrics.controlRadius)
            )
        }
        .buttonStyle(TranscriptionButtonStyle())
        .accessibilityAddTraits(displayMode == mode ? .isSelected : [])
    }

    func formatWithTimestamps(_ segments: [TranscriptionSegmentData]) -> String {
        TranscriptionViewLogic.timestampedTranscript(segments)
    }

    /// The mode `exportableTranscript` really produces. Timestamps and
    /// Speakers need data that may not exist (no segments, diarization not
    /// run or not finished) and fall back to the plain transcript.
    private var exportedMode: DisplayMode {
        TranscriptionViewLogic.exportedMode(
            for: displayMode,
            hasSegments: !viewModel.segments.isEmpty,
            hasSpeakerTurns: viewModel.speakerTurns != nil
        )
    }

    /// Speakers mode is selected but the speaker-labelled text doesn't exist
    /// (yet), so the pane shows a status instead of a transcript. Save, Copy
    /// and Process wait for the text rather than quietly handing over the
    /// unlabelled transcript; they always act on what is on screen.
    ///
    /// Two cases show the plain transcript instead, because it is all there
    /// is and no status would be true: a run that is still streaming
    /// (diarization can't have started), and a run that failed before it
    /// produced segments (there is nothing to diarize, and its partial
    /// transcript must stay visible).
    private var speakerTextPending: Bool {
        guard displayMode == .speakers, exportedMode != .speakers, !viewModel.isTranscribing else {
            return false
        }
        return !(viewModel.segments.isEmpty && viewModel.errorMessage != nil)
    }

    /// Save and Copy have nothing (final) to act on.
    private var exportDisabled: Bool {
        viewModel.isTranscribing || viewModel.transcribedText.isEmpty || speakerTextPending
    }

    /// The transcript formatted per the active display mode — used by display,
    /// "Spara som..." and "Kopiera text" so exports match what's on screen.
    /// Falls back to the plain transcript when the mode's data isn't available
    /// (see `exportedMode`).
    var exportableTranscript: String {
        switch exportedMode {
        case .transcript:
            return viewModel.transcribedText
        case .segments:
            return formatAsSegments(viewModel.transcribedText)
        case .timestamps:
            return formatWithTimestamps(viewModel.segments)
        case .speakers:
            return formatWithSpeakers(viewModel.segments, turns: viewModel.speakerTurns ?? [])
        }
    }

    /// Popover label key and filename suffix for what is actually exported —
    /// a fallback to the plain transcript is named as one.
    private var exportModeLabelKey: String {
        switch exportedMode {
        case .transcript: return "transcript"
        case .segments: return "segments"
        case .timestamps: return "timestamps"
        case .speakers: return "speakers"
        }
    }

    /// Localised like the label, so a file is named the way the UI names its
    /// mode; the string tables keep these ASCII.
    private var exportModeSuffix: String {
        switch exportedMode {
        case .transcript: return localized("file_suffix_transcript")
        case .segments: return localized("file_suffix_segments")
        case .timestamps: return localized("file_suffix_timestamps")
        case .speakers: return localized("file_suffix_speakers")
        }
    }

    /// Speaker-labeled transcript via the shared tuned pipeline in
    /// TranscribeKit (word-level assignment, turn cleaning) — the same code
    /// path the iOS app uses.
    func formatWithSpeakers(_ segments: [TranscriptionSegmentData], turns: [SpeakerTurn]) -> String {
        SpeakerTranscriptFormatter.format(
            segments: segments,
            turns: turns,
            speakerName: { viewModel.speakerDisplayName($0) },
            unknownLabel: localized("speaker_unknown")
        )
    }

    func formatAsSegments(_ text: String) -> String {
        TranscriptionViewLogic.sentenceParagraphs(text)
    }
    
    @ViewBuilder
    private func exportPopoverButton(icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundColor(enabled ? .textPrimary : .textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
        .pointerStyle(enabled ? .link : nil)
    }
    
    @ViewBuilder
    private func promptPopoverRow(name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primaryAccent)
                        .frame(width: 16)
                } else {
                    Spacer().frame(width: 16)
                }
                Text(name)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .pointerStyle(.link)
    }
    
    private var sectionDisabled: Bool {
        viewModel.isTranscribing || viewModel.transcribedText.isEmpty
    }
    
    private var processButtonDisabled: Bool {
        // While a request is streaming the button is its Cancel button
        if isProcessingLLM { return false }
        return sectionDisabled || selectedPrompt == nil || speakerTextPending || !hasLLMModelSelected
    }

    /// The selected prompt, as long as it still exists in Settings.
    private var selectedPrompt: TextProcessingPrompt? {
        guard let id = selectedPromptId else { return nil }
        return settingsManager.textProcessingPrompts.first { $0.id == id }
    }
    
    private var hasLLMModelSelected: Bool {
        let provider = settingsManager.preferredLLMProvider
        if provider == "berget" {
            return !settingsManager.bergetKey.isEmpty && !settingsManager.selectedBergetLLMModel.isEmpty && !settingsManager.localOnlyMode
        } else {
            return !settingsManager.selectedOllamaModel.isEmpty
        }
    }
    
    private var selectedLLMDisplayName: String {
        let provider = settingsManager.preferredLLMProvider
        if provider == "berget" {
            if settingsManager.bergetKey.isEmpty {
                return localized("select_model")
            }
            // Look up in the live catalog; a selection missing from it
            // (decommissioned model) shows its raw id as a hint to repick
            if let model = bergetCatalog.llmModels.first(where: { $0.id == settingsManager.selectedBergetLLMModel }) {
                return model.name
            }
            if !settingsManager.selectedBergetLLMModel.isEmpty {
                return settingsManager.selectedBergetLLMModel
            }
            return localized("select_model")
        } else {
            if settingsManager.selectedOllamaModel.isEmpty {
                return localized("select_model")
            }
            return settingsManager.selectedOllamaModel
        }
    }
    
    /// Cloud LLM models are offered when an API key is set and local-only
    /// mode is off.
    private var showsBergetLLMModels: Bool {
        !settingsManager.bergetKey.isEmpty && !settingsManager.localOnlyMode
    }

    /// One line of explanation where the popover would otherwise list models.
    private func llmPopoverNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
    }

    private var llmModelPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Berget section (API key configured, not local-only)
            if showsBergetLLMModels {
                HStack(spacing: 5) {
                    Image(systemName: "cloud")
                        .font(.system(size: 10))
                    Text("Berget AI – \(localized("cloud_models"))")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                
                ForEach(bergetCatalog.llmModels) { model in
                    llmPopoverRow(
                        name: model.name,
                        subtitle: model.isStable ? "" : model.lifecycleState,
                        isSelected: settingsManager.preferredLLMProvider == "berget" && settingsManager.selectedBergetLLMModel == model.id
                    ) {
                        settingsManager.preferredLLMProvider = "berget"
                        settingsManager.selectedBergetLLMModel = model.id
                        showLLMPopover = false
                    }
                }

                // The catalog is fetched from the network and can be empty
                if bergetCatalog.llmModels.isEmpty {
                    llmPopoverNote(localized("berget_models_unavailable"))
                }
            }
            
            // Ollama section (only if models available)
            if !settingsManager.ollamaModels.isEmpty {
                if showsBergetLLMModels {
                    Divider().padding(.horizontal, 12).padding(.vertical, 4)
                }
                
                HStack(spacing: 5) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 10))
                    Text("Ollama – \(localized("local_models"))")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, showsBergetLLMModels ? 0 : 8)
                .padding(.bottom, 4)
                
                ForEach(settingsManager.ollamaModels, id: \.self) { model in
                    llmPopoverRow(
                        name: model,
                        subtitle: nil,
                        isSelected: settingsManager.preferredLLMProvider == "ollama" && settingsManager.selectedOllamaModel == model
                    ) {
                        settingsManager.preferredLLMProvider = "ollama"
                        settingsManager.selectedOllamaModel = model
                        showLLMPopover = false
                    }
                }
            }
            
            // Neither section rendered: say why there is nothing to pick.
            // Local-only mode hides the cloud models even with a key set.
            if !showsBergetLLMModels && settingsManager.ollamaModels.isEmpty {
                llmPopoverNote(localized(settingsManager.localOnlyMode
                                         ? "llm_unavailable_local_only"
                                         : "llm_unavailable_no_provider"))
            }
        }
        .frame(width: 260)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func llmPopoverRow(name: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name)
                    .foregroundColor(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.textTertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.primaryAccent)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .pointerStyle(.link)
    }
    
    private func processTranscription() {
        guard let prompt = selectedPrompt else {
            return
        }
        
        // Build system prompt from selected prompt + additional info
        var systemPrompt = prompt.prompt
        if !additionalPromptInfo.isEmpty {
            systemPrompt += "\n\n" + localized("additional_information") + ":\n" + additionalPromptInfo
        }
        
        // Send the transcript as formatted by the active display mode — with
        // speaker names or timestamps included, the LLM can attribute
        // statements and reference moments instead of guessing.
        let transcription = exportableTranscript
        let provider: LLMService.Provider = settingsManager.preferredLLMProvider == "berget" ? .berget : .ollama
        let model = provider == .berget ? settingsManager.selectedBergetLLMModel : settingsManager.selectedOllamaModel
        let apiKey = settingsManager.bergetKey
        let ollamaHost = settingsManager.ollamaHost
        
        isProcessingLLM = true
        viewModel.processedText = ""
        
        let llmService = LLMService()
        
        llmTask = Task {
            do {
                let stream = llmService.streamCompletion(
                    systemPrompt: systemPrompt,
                    userMessage: transcription,
                    provider: provider,
                    model: model,
                    apiKey: apiKey,
                    ollamaHost: ollamaHost
                )
                
                for try await token in stream {
                    // Cancelled between tokens: nothing more may be appended
                    if Task.isCancelled { break }
                    viewModel.processedText += token
                }
            } catch {
                if !Task.isCancelled {
                    viewModel.processedText += "\n\n" + String(format: localized("llm_processing_failed"), error.localizedDescription)
                }
            }
            
            // After a cancel the state belongs to whoever cancelled — it has
            // been reset already, and a newer request may be running
            guard !Task.isCancelled else { return }
            isProcessingLLM = false
        }
    }
    
    private var selectedPromptName: String {
        if let prompt = selectedPrompt {
            return prompt.name
        }
        return localized("select_prompt")
    }
    
    private var additionalInfoSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(localized("additional_information"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                Button(action: { showAdditionalInfoSheet = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.textTertiary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(localized("close"))
                .accessibilityLabel(localized("close"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            // Description
            Text(localized("additional_info_description"))
                .font(.system(size: 12))
                .foregroundColor(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            
            // Text editor
            TextEditor(text: $additionalInfoDraft)
                .font(.system(size: 13))
                .padding(8)
                .frame(minHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.elevatedSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.borderLight, lineWidth: 1)
                )
                .padding(.horizontal, 20)
            
            Spacer()
            
            // Buttons
            HStack(spacing: 12) {
                Button(action: {
                    additionalInfoDraft = ""
                    additionalPromptInfo = ""
                    showAdditionalInfoSheet = false
                }) {
                    Text(localized("clear"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(.textSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.borderLight, lineWidth: 1)
                        )
                }
                .buttonStyle(TranscriptionButtonStyle())
                
                Button(action: {
                    additionalPromptInfo = additionalInfoDraft
                    showAdditionalInfoSheet = false
                }) {
                    Text(localized("save"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primaryAccent)
                        )
                }
                .buttonStyle(TranscriptionButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 420, height: 320)
        .background(Color.surfaceBackground)
    }
}

// MARK: - Pure logic

/// Rules of the transcription view that depend on nothing but their inputs,
/// kept apart from the view so they can be unit-tested
/// (TranscriptionViewLogicTests).
enum TranscriptionViewLogic {

    static func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Timestamps mode: one "[MM:SS] text" entry per segment. Entries are
    /// separated by a blank line, as in the Segments and Speakers modes — with
    /// single newlines the Markdown export collapses into one paragraph.
    static func timestampedTranscript(_ segments: [TranscriptionSegmentData]) -> String {
        segments.map { segment in
            "[\(formatTime(segment.start))] \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n\n")
    }

    /// Segments mode: one sentence per paragraph.
    static func sentenceParagraphs(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        var result = ""
        for (index, token) in tokens.enumerated() {
            result += token
            guard index < tokens.count - 1 else { break }
            let next = tokens[(index + 1)...].first { !$0.isEmpty }
            result += endsSentence(token, before: next) ? "\n\n" : " "
        }
        return result
    }

    /// Whether a sentence ends after `token`, given the word that follows.
    /// "!" and "?" always end one. A period does not when it belongs to an
    /// abbreviation ("t.ex.", "kl.", an initial) or when the next word starts
    /// in lowercase, so text isn't broken in the middle of a sentence; the
    /// cost is that a sentence which really ends in an abbreviation stays in
    /// the same paragraph as the next one.
    private static func endsSentence(_ token: Substring, before next: Substring?) -> Bool {
        guard let next, let last = token.last else { return false }
        if last == "!" || last == "?" { return true }
        guard last == "." else { return false }
        if next.first?.isLowercase == true { return false }

        let stem = token.dropLast().drop { !$0.isLetter && !$0.isNumber }
        // "..." trails off; what follows starts a new sentence
        if stem.last == "." { return true }
        // Periods inside the word: "t.ex.", "bl.a.", "f.eks.", "e.g."
        if stem.contains("."), stem.allSatisfy({ $0.isLetter || $0 == "." }) { return false }
        // An initial: "A. Lindgren". Uppercase only — sentences do end in
        // one-letter words ("huset vi bor i.")
        if stem.count == 1, stem.first?.isUppercase == true { return false }
        return !nonTerminalAbbreviations.contains(stem.lowercased())
    }

    /// Single-period abbreviations (Swedish, Norwegian, English) that lead
    /// into a name or a number rather than ending a sentence. Abbreviations
    /// with inner periods are recognised by their shape instead.
    private static let nonTerminalAbbreviations: Set<String> = [
        "kl", "ca", "nr", "dr", "prof", "mr", "mrs", "ms", "st", "vs",
        "dvs", "resp", "inkl", "exkl", "jfr", "jf", "evt", "pga", "mht",
        "tel", "tfn", "sid", "kap", "fig", "approx",
    ]

    /// Where a seek request lands, or nil when it is at or past the end of
    /// the audio and should end playback instead. Negative times clamp to
    /// the start.
    static func seekTarget(for time: Double, duration: Double) -> Double? {
        guard time < duration else { return nil }
        return max(time, 0)
    }

    /// The mode whose formatting an export (or the pane) really gets.
    /// Timestamps needs segments and Speakers needs segments plus speaker
    /// turns; without them the plain transcript is used.
    static func exportedMode(
        for mode: TranscriptionView.DisplayMode,
        hasSegments: Bool,
        hasSpeakerTurns: Bool
    ) -> TranscriptionView.DisplayMode {
        switch mode {
        case .transcript, .segments:
            return mode
        case .timestamps:
            return hasSegments ? .timestamps : .transcript
        case .speakers:
            return hasSegments && hasSpeakerTurns ? .speakers : .transcript
        }
    }
}

@MainActor
class TranscriptionViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var transcribedText = ""
    @Published var isTranscribing = false
    @Published var progress: Double = 0
    @Published var wordCount = 0
    
    /// Approximate token count for LLM context estimation (~4 chars per token)
    var estimatedTokenCount: Int {
        max(1, transcribedText.count / 4)
    }
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackSpeed: Double = 1.0 {
        didSet {
            audioPlayer?.rate = Float(playbackSpeed)
        }
    }
    @Published var segments: [TranscriptionSegmentData] = []
    @Published var speakerTurns: [SpeakerTurn]? = nil
    @Published var isDiarizing = false
    @Published var diarizationProgress: Double = 0
    @Published var diarizationError: String? = nil
    /// User-assigned display names per speaker id (e.g. 0: "Cecilia").
    @Published var speakerNames: [Int: String] = [:]
    /// Known speaker count to pin clustering with; nil = auto-estimate.
    @Published var speakerCountHint: Int? = nil
    /// Speaker turns came from Berget's server-side diarization — the local
    /// speaker-count control doesn't apply (the API has no such knob).
    @Published var isCloudDiarization = false
    private var diarizationTask: Task<Void, Never>?
    /// Identifies the current diarization run. Cancelling a run does not
    /// stop the diarizer at once, so a run that still reports progress or a
    /// result after being cancelled is recognised by its stale id and ignored.
    private var diarizationRunID = 0
    /// The view is showing the Speakers mode. Diarization needs a finished
    /// run's segments; when the mode is chosen before they exist (or the run
    /// is redone while it is showing), `finishTranscription()` starts it.
    private var speakersModeActive = false

    /// Distinct speaker ids present in the diarization result, sorted.
    var detectedSpeakerIds: [Int] {
        guard let turns = speakerTurns else { return [] }
        return Array(Set(turns.map(\.speakerId))).sorted()
    }
    @Published var elapsedTime: Double = 0
    @Published var estimatedTimeRemaining: Double = 0
    /// Why the most recent run failed or is incomplete; nil otherwise. Shown
    /// in its own card — never written into `transcribedText`, which holds
    /// only what was actually transcribed.
    @Published var errorMessage: String?
    /// The most recent run was cancelled before it finished. With no text
    /// and no error, this is what tells "cancelled" from "no speech found".
    @Published private(set) var wasCancelled = false
    /// The model the current (or most recent) run uses. The toolbar
    /// selection can change while a run is in flight; this does not.
    @Published private(set) var activeModelId = ""
    @Published var transcriptionTime: Double = 0
    @Published var statusMessage: String = ""
    @Published var currentChunk = 0
    @Published var totalChunks = 0
    @Published var chunkProgress: Double = 0
    @Published var isPreprocessing = false
    @Published var showSingleFileProgress = false
    @Published var singleFileProgress: Double = 0
    @Published var isProcessingChunks = false
    @Published var failedChunks: [Int] = []
    @Published var showExportError = false
    /// The current transcript has been copied or written to a file.
    @Published private(set) var hasExported = false

    /// The content changed after it was saved or copied.
    func markUnsaved() {
        if hasExported { hasExported = false }
    }
    @Published var exportErrorMessage = ""
    @Published var processedText = ""
    /// True while the user is dragging the playback slider — the playback timer
    /// must not overwrite `currentTime` during a scrub.
    @Published var isScrubbing = false
    
    let fileURL: URL
    var fileName: String {
        fileURL.lastPathComponent
    }
    
    var fileFormat: String {
        fileURL.pathExtension.uppercased()
    }
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var transcriptionService: TranscriptionService?  // For WhisperKit streaming
    private let unifiedTranscriptionService = UnifiedTranscriptionService()  // For KB models
    private var bergetService: BergetTranscriptionService?
    private var transcriptionStartTime: Date?
    private var transcriptionTimer: Timer?
    /// Advances the estimated-progress bar while a cloud request is out.
    private var cloudProgressTimer: Timer?
    private var transcriptionTask: Task<Void, Never>?
    /// Identifies the current transcription run. It changes when a run starts
    /// and when one is cancelled, so whatever an earlier run still delivers
    /// (a queued stream update, a cloud response that was already in flight)
    /// can tell it has been superseded and leave the view model alone.
    private var runID = 0
    /// False until the first run starts. Only once a run has been started
    /// does "not transcribing, no text" mean that a run ended with nothing.
    private(set) var hasStartedRun = false
    
    // Get selected model from UserDefaults
    @AppStorage("selectedTranscriptionModel") private var selectedModel: String = "kb_whisper-small-coreml"
    private var bergetKey: String {
        KeychainHelper.get("bergetAPIKey") ?? ""
    }
    
    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
        setupAudioPlayer()
    }

    deinit {
        timer?.invalidate()
        transcriptionTimer?.invalidate()
        cloudProgressTimer?.invalidate()
        audioPlayer?.stop()
    }

    func setupAudioPlayer() {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.enableRate = true // Enable rate adjustment
            audioPlayer?.rate = Float(playbackSpeed)
            duration = audioPlayer?.duration ?? 0
        } catch {
            // Audio player setup failed (e.g. video containers) — the view hides
            // playback controls when duration == 0
            duration = 0
        }
    }

    /// Cancels any in-flight transcription/LLM work, stops playback, and invalidates timers.
    /// Called when the view is dismissed or replaced.
    func cancelActiveWork() {
        // End the run as cancelled and give it a stale id: a cloud request
        // cannot be recalled here, and its response must not be applied
        endRunIfStillActive(runID)
        runID += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionService?.cancelTranscription()
        cancelDiarization()
        timer?.invalidate()
        timer = nil
        audioPlayer?.stop()
        isPlaying = false
    }

    /// Whether `run` is still the run in flight: not superseded by a newer
    /// one, and not cancelled.
    private func isCurrentRun(_ run: Int) -> Bool {
        run == runID && !Task.isCancelled
    }

    /// Ends `run` as cancelled: it is being cancelled or replaced, or its task
    /// stopped without a result or an error. Nothing happens if the run has
    /// already ended or been superseded, so every exit of a run's task can
    /// call this; it is what keeps `isTranscribing` from staying set with
    /// nothing running.
    private func endRunIfStillActive(_ run: Int) {
        guard run == runID, isTranscribing else { return }
        wasCancelled = true
        finishTranscription()
    }

    /// Tells the view model whether the Speakers mode is showing, and starts
    /// diarization if its input is ready. If not, `finishTranscription()`
    /// starts it once the run has produced segments.
    func setSpeakersModeActive(_ active: Bool) {
        speakersModeActive = active
        if active {
            startDiarizationIfNeeded()
        }
    }

    /// Stops diarization and makes sure nothing the stopped run still
    /// delivers is applied. The task is kept: the diarizer may not stop at
    /// once, and the next run waits for it (see startDiarizationIfNeeded).
    private func cancelDiarization() {
        diarizationRunID += 1
        diarizationTask?.cancel()
        isDiarizing = false
    }

    /// Re-runs diarization with a pinned (or auto) speaker count.
    /// Assigned names are kept — cluster ids usually remain stable in order.
    func rediarize(speakerCount: Int?) {
        guard speakerCountHint != speakerCount || speakerTurns == nil else { return }
        speakerCountHint = speakerCount
        cancelDiarization()
        speakerTurns = nil
        startDiarizationIfNeeded()
    }

    /// Debug: dumps turns/segments/words as JSON for benchmark scoring
    /// (scripts/score_diarization.py). Enable with:
    /// defaults write com.mickekring.transcribe.Transcribe diarizationDebugExport -bool true
    /// Debug builds only: it writes transcript text to permanent storage,
    /// which the released app promises never to do.
    func exportDiarizationDebug(source: String) {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "diarizationDebugExport") else { return }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundleId = Bundle.main.bundleIdentifier else { return }
        let dir = appSupport.appendingPathComponent(bundleId).appendingPathComponent("DiarizationDebug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let payload: [String: Any] = [
            "source": source,
            "options": DiarizationService.shared.lastOptionsDescription,
            "file": fileURL.lastPathComponent,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "turns": (speakerTurns ?? []).map { ["speaker": $0.speakerId, "start": $0.start, "end": $0.end] },
            "segments": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
            "words": segments.flatMap { $0.words ?? [] }.map { ["word": $0.word, "start": $0.start, "end": $0.end] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        let name = fileURL.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        try? data.write(to: dir.appendingPathComponent("\(name)-\(source)-\(stamp).json"))
        #endif
    }

    /// Display name for a speaker id: user-assigned, or "Talare N".
    func speakerDisplayName(_ id: Int) -> String {
        if let name = speakerNames[id], !name.isEmpty {
            return name
        }
        return String(format: localized("speaker_label"), id + 1)
    }

    /// Runs speaker diarization once per file; results are cached in
    /// `speakerTurns`. Requires local transcription segments for alignment.
    func startDiarizationIfNeeded() {
        guard speakerTurns == nil, !isDiarizing, !segments.isEmpty else { return }
        isDiarizing = true
        diarizationError = nil
        diarizationProgress = 0
        diarizationRunID += 1
        let run = diarizationRunID
        let previousRun = diarizationTask

        diarizationTask = Task {
            // A cancelled run can still be inside the diarizer — a fast
            // re-transcription gets here before it has wound down. Runs share
            // one diarizer instance, so they go one at a time.
            await previousRun?.value
            guard run == diarizationRunID else { return }
            do {
                let turns = try await DiarizationService.shared.diarize(
                    fileURL: fileURL,
                    numberOfSpeakers: speakerCountHint
                ) { progress in
                    DispatchQueue.main.async {
                        guard run == self.diarizationRunID else { return }
                        self.diarizationProgress = progress
                    }
                }
                await MainActor.run {
                    guard run == self.diarizationRunID else { return }
                    self.speakerTurns = turns
                    self.isDiarizing = false
                    self.exportDiarizationDebug(source: "local")
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard run == self.diarizationRunID else { return }
                    self.isDiarizing = false
                }
            } catch {
                await MainActor.run {
                    guard run == self.diarizationRunID else { return }
                    self.diarizationError = error.localizedDescription
                    self.isDiarizing = false
                }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.resetPlaybackToStart()
        }
    }
    
    /// The end-of-playback state: stopped and rewound to 0:00.
    private func resetPlaybackToStart() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        currentTime = 0
        audioPlayer?.currentTime = 0
    }

    func retranscribe() {
        // Speaker turns and LLM output describe the transcript being
        // replaced; they must not show up next to the new one
        cancelDiarization()
        processedText = ""

        // Reset all state for a fresh transcription
        transcribedText = ""
        wordCount = 0
        progress = 0
        segments = []
        speakerTurns = nil
        isCloudDiarization = false
        diarizationError = nil
        errorMessage = nil
        statusMessage = ""
        transcriptionTime = 0
        transcriptionStartTime = nil
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil
        currentChunk = 0
        totalChunks = 0
        chunkProgress = 0
        isPreprocessing = false
        showSingleFileProgress = false
        singleFileProgress = 0
        isProcessingChunks = false
        failedChunks = []
        
        // Start fresh
        startTranscription()
    }
    
    func startTranscription() {
        // A new run produces a new transcript
        hasExported = false
        // A new run replaces one that is still in flight. Ending that one
        // first stops its timers and clears its progress state; the new run
        // id makes whatever it still delivers stale.
        endRunIfStillActive(runID)
        transcriptionTask?.cancel()
        runID += 1
        let run = runID
        hasStartedRun = true
        activeModelId = selectedModel
        wasCancelled = false
        errorMessage = nil
        // Each run has its own clock
        transcriptionStartTime = nil
        transcriptionTime = 0
        isTranscribing = true
        // Note: the transcription clock starts when actual transcription text arrives
        // (local) or the upload begins (cloud), not here — model loading and audio
        // preparation shouldn't count as transcription time.
        
        // Get selected language
        let selectedLanguage = LanguageManager.shared.selectedLanguage.code == "auto" ? nil : LanguageManager.shared.selectedLanguage.code
        
        // Determine which service to use based on selected model
        if ModelManager.engine(for: selectedModel) == .cloud {
            guard !UserDefaults.standard.bool(forKey: "localOnlyMode") else {
                failTranscription(localized("local_only_cloud_blocked"))
                return
            }
            // Cloud transcription (id format "berget:<api model id>";
            // legacy "berget-kb-whisper-large" maps to the KB model)
            let apiModel = selectedModel.hasPrefix("berget:")
                ? String(selectedModel.dropFirst("berget:".count))
                : "KBLab/kb-whisper-large"
            startBergetTranscription(model: apiModel, language: selectedLanguage, run: run)
        } else {
            // Local engines (WhisperKit, Parakeet). An id no engine claims
            // goes this way too: TranscriptionService reports it as unsupported.
            startLocalTranscription(run: run)
        }
    }
    
    private func startLocalTranscription(run: Int) {
        statusMessage = localized("processing_local_model")
        
        // TranscriptionService streams the same updates for every local engine
        startWhisperKitTranscription(run: run)
    }
    
    private func startWhisperKitTranscription(run: Int) {
        let service = TranscriptionService()
        transcriptionService = service

        transcriptionTask = Task {
            // Cancelled or replaced before it got to run: don't start the
            // engine at all
            guard isCurrentRun(run) else {
                endRunIfStillActive(run)
                return
            }
            do {
                // Stream transcription updates
                for try await update in service.transcribe(fileURL: fileURL) {
                    // An update that was already queued when the run was
                    // cancelled or replaced is not applied. The rest of the
                    // iteration runs on the main actor without suspending,
                    // so a cancel cannot land between this check and the
                    // writes below.
                    guard isCurrentRun(run) else { break }
                    if update.progress < 0.15 && !update.isComplete {
                        // Low-progress updates are status messages (model loading, init, etc.)
                        // Show as status text, don't set as transcribed text
                        self.statusMessage = update.text
                    } else if !update.isComplete && update.text == localized("transcribing") {
                        // WhisperKit sends this placeholder as content until
                        // it has decoded some text. It is a status as well:
                        // kept as transcript it would be counted, exported,
                        // and left behind as a "partial transcript" if the
                        // run then failed. Decoding has begun, though, so
                        // the clock starts.
                        self.statusMessage = update.text
                        self.startTranscriptionClock()
                    } else {
                        // Actual transcription content
                        self.transcribedText = update.text
                        self.progress = update.progress
                        self.segments = update.segments
                        self.wordCount = update.text.split(separator: " ").count
                        self.statusMessage = ""
                            
                        // Start transcription timer on first real content
                        self.startTranscriptionClock()
                    }
                        
                    if update.isComplete {
                        self.finishTranscription()
                    }
                }
            } catch is CancellationError {
                // User-initiated stop — no error UI; the run is ended below
            } catch {
                // A failure that comes in after the run was cancelled or
                // replaced is not a result to show
                if isCurrentRun(run) {
                    handleTranscriptionError(error)
                }
            }
            // A cancelled stream ends without a final update and without an
            // error; the run must not stay marked as in flight
            endRunIfStillActive(run)
        }
    }

    /// Starts the clock behind the transcription-time stat, once per run.
    private func startTranscriptionClock() {
        guard transcriptionStartTime == nil else { return }
        transcriptionStartTime = Date()
        // Timer blocks are @Sendable, but a timer fires on the run loop it
        // was scheduled on. The view model only schedules from the main
        // actor, so its timer blocks run on the main thread and may assume
        // main-actor isolation (checked at runtime).
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startTime = self.transcriptionStartTime else { return }
                self.transcriptionTime = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func startBergetTranscription(model: String, language: String?, run: Int) {
        guard !bergetKey.isEmpty else {
            failTranscription(localized("berget_api_key_missing"))
            return
        }
        
        statusMessage = localized("preparing_audio_file")
        let service = BergetTranscriptionService(apiKey: bergetKey, model: model)
        bergetService = service

        transcriptionTask = Task {
            // Cancelled or replaced before it got to run
            guard isCurrentRun(run) else {
                endRunIfStillActive(run)
                return
            }
            do {
                // Preprocess audio
                isPreprocessing = true
                
                let processedAudio = try await AudioPreprocessor.shared.preprocessAudio(
                    url: fileURL,
                    onProgress: { message in
                        DispatchQueue.main.async {
                            guard run == self.runID else { return }
                            self.statusMessage = message
                        }
                    }
                )
                // Temporary files go when this scope is left, however the run
                // ends. Requests are awaited even after a cancel, so a file is
                // never deleted while an upload is still reading it.
                defer { AudioPreprocessor.shared.cleanupProcessedAudio(processedAudio) }
                
                // Preprocessing does not observe cancellation; a run that was
                // cancelled meanwhile stops here, before anything is uploaded
                if isCurrentRun(run) {
                    isPreprocessing = false
                    totalChunks = processedAudio.chunks.count
                    // Preparation is over: what follows is transcription time
                    startTranscriptionClock()

                    if processedAudio.chunks.count > 1 {
                        // Handle chunked transcription
                        await transcribeChunksWithBerget(processedAudio: processedAudio, language: language, service: service, run: run)
                    } else if let chunk = processedAudio.chunks.first {
                        // Single file transcription
                        await transcribeSingleFileWithBerget(url: chunk.url, language: language, service: service, run: run)
                    } else {
                        failTranscription(localized("no_audio_in_file"))
                    }
                }
            } catch is CancellationError {
                // User-initiated stop — no error UI; the run is ended below
            } catch {
                // A failure that comes in after the run was cancelled or
                // replaced is not a result to show
                if isCurrentRun(run) {
                    handleTranscriptionError(error)
                }
            }
            // A run that stopped because it was cancelled has no result and
            // no error, but must not stay marked as in flight
            endRunIfStillActive(run)
        }
    }
    
    /// Sends one file to Berget and suspends until the service calls back.
    /// The response is reduced to a `CloudTranscript` inside the completion
    /// handler: `TranscriptionResult` is not Sendable, so the handler must not
    /// pass it on to the main actor.
    private func cloudTranscript(
        from service: BergetTranscriptionService,
        audioURL: URL,
        language: String?,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Result<CloudTranscript, Error> {
        await withCheckedContinuation { continuation in
            service.transcribe(
                audioURL: audioURL,
                language: language,
                onProgress: onProgress,
                completion: { result in
                    continuation.resume(returning: result.map { CloudTranscript($0) })
                }
            )
        }
    }

    private func transcribeSingleFileWithBerget(url: URL, language: String?, service: BergetTranscriptionService, run: Int) async {
        // Set directly: this already runs on the main actor, and a hop would
        // let a cancel slip in between the caller's check and these writes
        statusMessage = localized("sending_audio_berget")
        showSingleFileProgress = true
        singleFileProgress = 0
        
        // Get duration for progress estimation
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        let durationInSeconds = duration != nil ? CMTimeGetSeconds(duration!) : 60.0
        let expectedTime = max(durationInSeconds / 9.0, 2.0) // 9x realtime with minimum 2 seconds
        
        // Cancelled while the duration was loading: nothing is uploaded
        guard isCurrentRun(run) else { return }

        // Start progress timer (isolation: see startTranscriptionClock)
        cloudProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.singleFileProgress = min(self.singleFileProgress + (0.1 / expectedTime), 0.95)
            }
        }
        
        // Wait for the upload to complete before returning so the caller doesn't
        // delete the temp file while the request is still reading it
        let outcome = await cloudTranscript(
            from: service,
            audioURL: url,
            language: language,
            onProgress: { text in
                DispatchQueue.main.async {
                    guard run == self.runID else { return }
                    self.transcribedText = text
                    self.wordCount = text.split(separator: " ").count
                    self.statusMessage = localized("transcribing")
                    self.singleFileProgress = min(self.singleFileProgress, 0.8) // Update progress if we get intermediate results
                }
            }
        )

        // A request cannot be recalled once sent. If the run was cancelled or
        // replaced while it was out, its response is dropped here.
        guard isCurrentRun(run) else { return }

        cloudProgressTimer?.invalidate()
        cloudProgressTimer = nil
        singleFileProgress = 1.0
        showSingleFileProgress = false

        switch outcome {
        case .success(let transcript):
            // Prefer joined segment text (clean) over the raw
            // text field, which may embed speaker prefixes
            let joined = transcript.segments.map(\.text).joined(separator: " ")
            // Trimmed, so a response without speech is an empty transcript
            transcribedText = (joined.isEmpty ? transcript.text : joined)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            segments = transcript.segments
            if !transcript.speakerTurns.isEmpty {
                speakerTurns = transcript.speakerTurns
                isCloudDiarization = true
                exportDiarizationDebug(source: "cloud")
            }
            wordCount = transcribedText.split(separator: " ").count
            finishTranscription()
        case .failure(let error):
            handleTranscriptionError(error)
        }
    }
    
    @MainActor
    private func transcribeChunksWithBerget(processedAudio: AudioPreprocessor.ProcessedAudio, language: String?, service: BergetTranscriptionService, run: Int) async {
        var transcriptionResults: [(chunk: AudioPreprocessor.AudioChunk, result: TranscriptionResult)] = []
        
        // Set flag to indicate we're processing chunks
        self.isProcessingChunks = true
        self.failedChunks = []
        
        for (index, chunk) in processedAudio.chunks.enumerated() {
            // Cancelled: the remaining chunks are not uploaded
            guard isCurrentRun(run) else { return }
            // Local-only mode switched on during the job: nothing more leaves
            // the computer (the service refuses too; this ends the run cleanly)
            if UserDefaults.standard.bool(forKey: "localOnlyMode") {
                isProcessingChunks = false
                failTranscription(localized("local_only_cloud_blocked"))
                return
            }

            self.currentChunk = index + 1
            self.statusMessage = String(format: localized("transcribing_chunk"), index + 1, processedAudio.chunks.count)
            self.chunkProgress = 0
            
            // Start a timer to simulate progress (9x realtime;
            // isolation: see startTranscriptionClock)
            let chunkDuration = chunk.endTime - chunk.startTime
            let expectedTime = chunkDuration / 9.0
            cloudProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.chunkProgress = min(self.chunkProgress + (0.1 / expectedTime), 0.95)
                }
            }
            
            let outcome = await cloudTranscript(
                from: service,
                audioURL: chunk.url,
                language: language,
                onProgress: { _ in
                    DispatchQueue.main.async {
                        guard run == self.runID else { return }
                        // Update chunk progress
                        self.chunkProgress = 0.5
                    }
                }
            )
                        
            // The response to a run that was cancelled or replaced while the
            // request was out is dropped, and the loop ends
            guard isCurrentRun(run) else { return }
                            
            cloudProgressTimer?.invalidate()
            cloudProgressTimer = nil
            self.chunkProgress = 1.0
                                
            switch outcome {
            case .success(let transcript):
                transcriptionResults.append((chunk: chunk, result: transcript.transcriptionResult))
                            
            case .failure:
                self.failedChunks.append(index + 1)
            }
        }
        
        // Merge results
        if !transcriptionResults.isEmpty {
            await MainActor.run {
                // MainActor.run suspends on the way in, so the run may have
                // been cancelled since the loop's last check
                guard self.isCurrentRun(run) else { return }
                self.statusMessage = localized("merging_results")
                
                let mergedResult = AudioPreprocessor.shared.mergeChunkedTranscriptions(transcriptionResults)
                
                if mergedResult.text.isEmpty && transcriptionResults.count > 0 {
                    // Fallback: just concatenate all texts if merge failed.
                    // Trimmed, so chunks without speech give an empty
                    // transcript rather than a few spaces.
                    self.transcribedText = transcriptionResults.map { $0.result.text }.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.segments = []
                } else {
                    self.transcribedText = mergedResult.text
                    self.segments = mergedResult.segments.map { segment in
                        TranscriptionSegmentData(
                            start: segment.start,
                            end: segment.end,
                            text: segment.text,
                            words: nil
                        )
                    }
                }
                
                // Some chunks failed: the transcript has gaps. Reported next
                // to it like an error — appended to the text it would be
                // counted, exported and sent to the LLM as if it were speech
                if !self.failedChunks.isEmpty {
                    let failedList = self.failedChunks.map { String($0) }.joined(separator: ", ")
                    self.errorMessage = String(format: localized("chunks_failed"), failedList, processedAudio.chunks.count)
                }
                
                self.wordCount = self.transcribedText.split(separator: " ").count
                self.isProcessingChunks = false
                self.finishTranscription()
            }
        } else {
            await MainActor.run {
                guard self.isCurrentRun(run) else { return }
                self.isProcessingChunks = false
                self.failTranscription(String(format: localized("all_chunks_failed"), processedAudio.chunks.count))
            }
        }
    }
    
    private func finishTranscription() {
        self.isTranscribing = false
        self.estimatedTimeRemaining = 0
        self.transcriptionTimer?.invalidate()
        self.transcriptionTimer = nil
        self.cloudProgressTimer?.invalidate()
        self.cloudProgressTimer = nil
        // Keep the final transcription time displayed
        if let startTime = self.transcriptionStartTime {
            self.transcriptionTime = Date().timeIntervalSince(startTime)
        }
        // Reset chunk tracking
        self.currentChunk = 0
        self.totalChunks = 0
        self.chunkProgress = 0
        self.isPreprocessing = false
        self.showSingleFileProgress = false
        self.singleFileProgress = 0
        self.isProcessingChunks = false
        self.statusMessage = ""

        // Speakers mode was chosen before this run had segments, or the run
        // was redone while it is showing: diarize now that they exist. Not
        // after a cancel — any segments then belong to an earlier run.
        if speakersModeActive && !wasCancelled {
            startDiarizationIfNeeded()
        }
    }

    /// Ends the run as failed. The message goes to `errorMessage` and from
    /// there to its own card; `transcribedText` keeps whatever was
    /// transcribed before the failure.
    private func failTranscription(_ message: String) {
        errorMessage = message
        finishTranscription()
    }
    
    private func handleTranscriptionError(_ error: Error) {
        failTranscription(error.localizedDescription)
    }
    
    func togglePlayPause() {
        if isPlaying {
            audioPlayer?.pause()
            timer?.invalidate()
        } else {
            audioPlayer?.rate = Float(playbackSpeed) // Apply current speed
            audioPlayer?.play()
            startTimer()
        }
        isPlaying.toggle()
    }
    
    func skipForward() {
        let newTime = min(currentTime + 10, duration)
        seek(to: newTime)
    }
    
    func skipBackward() {
        let newTime = max(currentTime - 10, 0)
        seek(to: newTime)
    }
    
    func seek(to time: Double) {
        guard let target = TranscriptionViewLogic.seekTarget(for: time, duration: duration) else {
            // At or past the end. Setting a playing AVAudioPlayer's
            // currentTime to its duration wraps around and keeps playing
            // from 0:00, so end playback here the way running off the end
            // does (audioPlayerDidFinishPlaying is not called for stop()).
            audioPlayer?.stop()
            resetPlaybackToStart()
            return
        }
        audioPlayer?.currentTime = target
        currentTime = target
    }
    
    func startTimer() {
        // Isolation: see startTranscriptionClock
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = self.audioPlayer?.currentTime ?? 0
            }
        }
    }
    
    /// Copies the given transcript (formatted by the view's active display
    /// mode) plus any processed text. Falls back to the raw transcription
    /// when no formatted text is passed.
    func copyToClipboard(_ transcript: String? = nil) {
        var combined = transcript ?? transcribedText
        if !processedText.isEmpty {
            combined += "\n\n---\n\n" + processedText
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        hasExported = true
    }
    
    private var baseName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }
    
    /// Exports transcript content already formatted by the view's active
    /// display mode (plain, segments, timestamps, or speakers).
    func exportText(_ content: String, suffix: String) {
        saveFile(content: content, defaultName: "\(baseName)_\(suffix).txt", contentType: .plainText)
    }

    func exportMarkdown(_ content: String, suffix: String) {
        let md = "# \(fileName)\n\n\(content)\n"
        saveFile(content: md, defaultName: "\(baseName)_\(suffix).md", contentType: UTType(filenameExtension: "md") ?? .plainText)
    }
    
    func exportProcessedAsText() {
        saveFile(content: processedText, defaultName: "\(baseName)_\(localized("file_suffix_processed")).txt", contentType: .plainText)
    }
    
    func exportProcessedAsMarkdown() {
        let md = "# \(fileName)\n\n\(processedText)\n"
        saveFile(content: md, defaultName: "\(baseName)_\(localized("file_suffix_processed")).md", contentType: UTType(filenameExtension: "md") ?? .plainText)
    }
    
    /// Copies the source audio file to a user-chosen location. Recordings live
    /// in a temp directory that is wiped on quit, so this is how users keep them.
    func saveAudioFile() {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = fileURL.lastPathComponent
        if let type = UTType(filenameExtension: fileURL.pathExtension) {
            savePanel.allowedContentTypes = [type]
        }
        savePanel.isExtensionHidden = false
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.copyItem(at: self.fileURL, to: url)
                } catch {
                    self.exportErrorMessage = error.localizedDescription
                    self.showExportError = true
                }
            }
        }
    }

    private func saveFile(content: String, defaultName: String, contentType: UTType) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = defaultName
        savePanel.allowedContentTypes = [contentType]
        savePanel.allowsOtherFileTypes = false
        savePanel.isExtensionHidden = false
        savePanel.canCreateDirectories = true
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    self.hasExported = true
                } catch {
                    self.exportErrorMessage = error.localizedDescription
                    self.showExportError = true
                }
            }
        }
    }
}



// MARK: - Cloud response

/// What the view model uses of a Berget response, as Sendable values. The
/// service hands its completion handler a `TranscriptionResult`, which is not
/// Sendable; this is built from it there, and only this crosses to the main
/// actor.
private struct CloudTranscript: Sendable {
    /// The response's own text field. It may embed speaker prefixes, so the
    /// segment texts are preferred where there are any.
    let text: String
    let segments: [TranscriptionSegmentData]
    /// Server-side diarization, empty when the response carried no speakers.
    let speakerTurns: [SpeakerTurn]

    init(_ result: TranscriptionResult) {
        text = result.text
        segments = result.segments.map { segment in
            TranscriptionSegmentData(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                words: segment.words?.map { word in
                    WordTimestamp(word: word.word, start: word.start, end: word.end, confidence: 1.0)
                }
            )
        }

        // Cloud diarization: prefer word-level speaker
        // labels (align+diarize) — they capture handovers
        // mid-segment; fall back to segment-level labels
        func speakerId(_ label: String?) -> Int? {
            guard let label else { return nil }
            return Int(label.components(separatedBy: "_").last ?? "")
        }
        var turns: [SpeakerTurn] = []
        let speakerWords = result.segments
            .flatMap { $0.words ?? [] }
            .compactMap { word -> (Int, Double, Double)? in
                guard let id = speakerId(word.speaker) else { return nil }
                return (id, word.start, word.end)
            }
        if !speakerWords.isEmpty {
            // Merge consecutive same-speaker words into turns
            for (id, start, end) in speakerWords {
                if let last = turns.last, last.speakerId == id {
                    turns[turns.count - 1] = SpeakerTurn(speakerId: id, start: last.start, end: end)
                } else {
                    turns.append(SpeakerTurn(speakerId: id, start: start, end: end))
                }
            }
        } else {
            turns = result.segments.compactMap { segment in
                guard let id = speakerId(segment.speaker) else { return nil }
                return SpeakerTurn(speakerId: id, start: segment.start, end: segment.end)
            }
        }
        speakerTurns = turns
    }

    /// Back in the package's type, for `AudioPreprocessor.mergeChunkedTranscriptions`.
    /// The merge reads the text and each segment's timing and text, which is
    /// what is restored; the remaining fields are placeholders.
    var transcriptionResult: TranscriptionResult {
        TranscriptionResult(
            text: text,
            segments: segments.enumerated().map { index, segment in
                TranscriptionSegment(
                    id: index,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    confidence: nil,
                    speaker: nil
                )
            },
            language: "",
            duration: 0,
            timestamp: Date(),
            modelUsed: ""
        )
    }
}

// MARK: - Auto-Scrolling Text View

/// NSViewRepresentable wrapping NSScrollView + NSTextView for reliable auto-scroll during streaming.
struct AutoScrollingTextView: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let isStreaming: Bool
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        let textColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0xED/255.0, green: 0xED/255.0, blue: 0xED/255.0, alpha: 1)
                : NSColor(red: 0x10/255.0, green: 0x10/255.0, blue: 0x15/255.0, alpha: 1)
        }
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize))
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: font
        ]
        
        let currentText = textView.string
        let fontChanged = context.coordinator.lastFontSize != fontSize
        if currentText != text || fontChanged {
            context.coordinator.lastFontSize = fontSize
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            
            // Auto-scroll to bottom while streaming
            if isStreaming {
                DispatchQueue.main.async {
                    textView.scrollToEndOfDocument(nil)
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastFontSize: Double = 0
    }
}
/// NSViewRepresentable that renders Markdown text with proper formatting and auto-scroll.
struct MarkdownTextView: NSViewRepresentable {
    let markdown: String
    let fontSize: Double
    let isStreaming: Bool
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        
        scrollView.documentView = textView
        context.coordinator.textView = textView
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        let fontChanged = context.coordinator.lastFontSize != fontSize
        let textChanged = context.coordinator.lastText != markdown
        
        guard textChanged || fontChanged else { return }
        
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastText = markdown
        
        let attributed = Self.renderMarkdown(markdown, fontSize: fontSize)
        textView.textStorage?.setAttributedString(attributed)
        
        if isStreaming {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        weak var textView: NSTextView?
        var lastFontSize: Double = 0
        var lastText: String = ""
    }
    
    /// Converts a Markdown string to a styled NSAttributedString.
    /// Uses a custom line-by-line parser for reliable heading, table, and list rendering
    /// from LLM output (Apple's NSAttributedString(markdown:) doesn't handle these well).
    static func renderMarkdown(_ markdown: String, fontSize: Double) -> NSAttributedString {
        let textColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0xED/255.0, green: 0xED/255.0, blue: 0xED/255.0, alpha: 1)
                : NSColor(red: 0x10/255.0, green: 0x10/255.0, blue: 0x15/255.0, alpha: 1)
        }
        let headingColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white
                : NSColor.black
        }
        let codeBackground = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(white: 0, alpha: 0.04)
        }
        let accentColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0x3E/255.0, green: 0xCF/255.0, blue: 0x8E/255.0, alpha: 1)
                : NSColor(red: 0x2E/255.0, green: 0xB5/255.0, blue: 0x7D/255.0, alpha: 1)
        }
        let tableBorderColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.15)
                : NSColor(white: 0, alpha: 0.15)
        }
        let tableHeaderBg = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.08)
                : NSColor(white: 0, alpha: 0.05)
        }
        
        let baseFontSize = CGFloat(fontSize)
        let baseFont = NSFont.systemFont(ofSize: baseFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: baseFontSize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .regular)
        
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        
        var i = 0
        var isFirstBlock = true
        
        /// Applies inline markdown formatting (**bold**, *italic*, `code`) to a plain text string
        func applyInlineStyles(to text: String, baseAttrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
            let styled = NSMutableAttributedString(string: text, attributes: baseAttrs)
            
            // Bold: **text** or __text__
            let boldPattern = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*|__(.+?)__")
            if let matches = boldPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                for match in matches.reversed() {
                    let contentRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                    let contentText = (text as NSString).substring(with: contentRange)
                    let replacement = NSAttributedString(string: contentText, attributes: baseAttrs.merging([
                        .font: boldFont,
                        .foregroundColor: headingColor
                    ]) { _, new in new })
                    styled.replaceCharacters(in: match.range, with: replacement)
                }
            }
            
            // Italic: *text* or _text_ (but not inside **). An underscore only
            // delimits emphasis at a word boundary, as in CommonMark — inside
            // a word it is part of the text (kb_whisper_small, snake_case).
            let italicPattern = try? NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)|(?<![\\p{L}\\p{N}_])_(?!_)(.+?)(?<!_)_(?![\\p{L}\\p{N}_])")
            if let matches = italicPattern?.matches(in: styled.string, range: NSRange(location: 0, length: styled.length)) {
                for match in matches.reversed() {
                    let contentRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                    let contentText = (styled.string as NSString).substring(with: contentRange)
                    let currentFont = styled.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont ?? baseFont
                    let italicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
                    var attrs = baseAttrs
                    attrs[.font] = italicFont
                    let replacement = NSAttributedString(string: contentText, attributes: attrs)
                    styled.replaceCharacters(in: match.range, with: replacement)
                }
            }
            
            // Inline code: `code`
            let codePattern = try? NSRegularExpression(pattern: "`([^`]+)`")
            if let matches = codePattern?.matches(in: styled.string, range: NSRange(location: 0, length: styled.length)) {
                for match in matches.reversed() {
                    let contentRange = match.range(at: 1)
                    let contentText = (styled.string as NSString).substring(with: contentRange)
                    let replacement = NSAttributedString(string: contentText, attributes: baseAttrs.merging([
                        .font: monoFont,
                        .backgroundColor: codeBackground
                    ]) { _, new in new })
                    styled.replaceCharacters(in: match.range, with: replacement)
                }
            }
            
            return styled
        }
        
        func addSpacingBefore(_ spacing: CGFloat) {
            if !isFirstBlock && result.length > 0 {
                // Add a newline with small font to create spacing
                let spacer = NSMutableAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: spacing),
                    .foregroundColor: NSColor.clear
                ])
                result.append(spacer)
            }
        }
        
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: textColor
        ]
        
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines (spacing handled by blocks)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            
            // --- Headings: # ## ### ####  ---
            if let headingMatch = trimmed.range(of: "^#{1,4}\\s+", options: .regularExpression) {
                let hashes = trimmed[headingMatch].filter { $0 == "#" }.count
                let headingText = String(trimmed[headingMatch.upperBound...])
                
                let headingSize: CGFloat
                switch hashes {
                case 1: headingSize = baseFontSize * 1.5
                case 2: headingSize = baseFontSize * 1.3
                case 3: headingSize = baseFontSize * 1.15
                default: headingSize = baseFontSize * 1.1
                }
                
                addSpacingBefore(baseFontSize * 0.6)
                
                let headingAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: headingSize),
                    .foregroundColor: headingColor
                ]
                let headingStr = applyInlineStyles(to: headingText, baseAttrs: headingAttrs)
                result.append(headingStr)
                result.append(NSAttributedString(string: "\n", attributes: headingAttrs))
                
                isFirstBlock = false
                i += 1
                continue
            }
            
            // --- Table: lines starting with | ---
            if trimmed.hasPrefix("|") {
                addSpacingBefore(baseFontSize * 0.3)
                
                // Collect all table lines
                var tableLines: [String] = []
                while i < lines.count {
                    let tl = lines[i].trimmingCharacters(in: .whitespaces)
                    if tl.hasPrefix("|") {
                        tableLines.append(tl)
                        i += 1
                    } else {
                        break
                    }
                }
                
                // Parse table: filter out separator rows (|---|---|)
                var rows: [[String]] = []
                var separatorIndex = -1
                for (idx, tl) in tableLines.enumerated() {
                    let isSeparator = tl.range(of: "^\\|[\\s\\-:|]+\\|$", options: .regularExpression) != nil
                    if isSeparator {
                        separatorIndex = idx
                        continue
                    }
                    // Split by | and filter out empty strings from leading/trailing |
                    let cleaned = tl.components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    rows.append(cleaned)
                }
                
                // Compute column widths based on content
                let colCount = rows.map { $0.count }.max() ?? 0
                guard colCount > 0 else { continue }
                
                // Render table rows
                for (rowIdx, row) in rows.enumerated() {
                    let isHeader = rowIdx == 0 && separatorIndex == 1
                    let rowFont = isHeader ? boldFont : baseFont
                    let rowColor = isHeader ? headingColor : textColor
                    
                    // Build row string with consistent column separators
                    var rowText = ""
                    for (colIdx, cell) in row.enumerated() {
                        if colIdx > 0 { rowText += "  │  " }
                        rowText += cell
                    }
                    // Pad remaining columns if row is short
                    for colIdx in row.count..<colCount {
                        if colIdx > 0 { rowText += "  │  " }
                    }
                    
                    let rowAttrs: [NSAttributedString.Key: Any] = [
                        .font: rowFont,
                        .foregroundColor: rowColor
                    ]
                    
                    let styledRow = applyInlineStyles(to: rowText, baseAttrs: rowAttrs)
                    let mutableRow = NSMutableAttributedString(attributedString: styledRow)
                    
                    // Add background for header row
                    if isHeader {
                        mutableRow.addAttribute(.backgroundColor, value: tableHeaderBg, range: NSRange(location: 0, length: mutableRow.length))
                    }
                    
                    // Style the column separators (│) in a dimmer color
                    let separatorPattern = try? NSRegularExpression(pattern: "│")
                    if let sepMatches = separatorPattern?.matches(in: mutableRow.string, range: NSRange(location: 0, length: mutableRow.length)) {
                        for match in sepMatches {
                            mutableRow.addAttribute(.foregroundColor, value: tableBorderColor, range: match.range)
                        }
                    }
                    
                    let rowParagraph = NSMutableParagraphStyle()
                    rowParagraph.paragraphSpacing = baseFontSize * 0.1
                    rowParagraph.lineSpacing = baseFontSize * 0.15
                    mutableRow.addAttribute(.paragraphStyle, value: rowParagraph, range: NSRange(location: 0, length: mutableRow.length))
                    
                    result.append(mutableRow)
                    result.append(NSAttributedString(string: "\n", attributes: rowAttrs))
                    
                    // Add a thin separator line after header
                    if isHeader {
                        var separatorLine = ""
                        for colIdx in 0..<colCount {
                            if colIdx > 0 { separatorLine += "──┼──" }
                            separatorLine += "──────"
                        }
                        let sepAttrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.7, weight: .regular),
                            .foregroundColor: tableBorderColor
                        ]
                        result.append(NSAttributedString(string: separatorLine + "\n", attributes: sepAttrs))
                    }
                }
                
                isFirstBlock = false
                continue
            }
            
            // --- Horizontal rule: --- or *** or ___ ---
            if trimmed.range(of: "^([-*_])\\1{2,}$", options: .regularExpression) != nil {
                addSpacingBefore(baseFontSize * 0.2)
                let rule = String(repeating: "─", count: 40)
                result.append(NSAttributedString(string: rule + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: baseFontSize * 0.5),
                    .foregroundColor: tableBorderColor
                ]))
                isFirstBlock = false
                i += 1
                continue
            }
            
            // --- Unordered list: - item, * item, + item ---
            if trimmed.range(of: "^[-*+]\\s+", options: .regularExpression) != nil {
                let listText = trimmed.replacingOccurrences(of: "^[-*+]\\s+", with: "", options: .regularExpression)
                
                if isFirstBlock { isFirstBlock = false } else if result.length > 0 {
                    // Small spacing between list items (less than between paragraphs)
                }
                
                let bullet = "•  "
                let bulletAttrs: [NSAttributedString.Key: Any] = [
                    .font: baseFont,
                    .foregroundColor: accentColor
                ]
                let listParagraph = NSMutableParagraphStyle()
                listParagraph.headIndent = baseFontSize * 1.5
                listParagraph.firstLineHeadIndent = baseFontSize * 0.4
                listParagraph.paragraphSpacing = baseFontSize * 0.1
                
                let itemStr = NSMutableAttributedString()
                itemStr.append(NSAttributedString(string: bullet, attributes: bulletAttrs))
                itemStr.append(applyInlineStyles(to: listText, baseAttrs: baseAttrs))
                itemStr.addAttribute(.paragraphStyle, value: listParagraph, range: NSRange(location: 0, length: itemStr.length))
                itemStr.append(NSAttributedString(string: "\n", attributes: baseAttrs))
                result.append(itemStr)
                
                isFirstBlock = false
                i += 1
                continue
            }
            
            // --- Ordered list: 1. item, 2. item ---
            if trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil {
                let listText = trimmed.replacingOccurrences(of: "^\\d+\\.\\s+", with: "", options: .regularExpression)
                let numberStr = trimmed.components(separatedBy: ".").first ?? "1"
                
                let bullet = "\(numberStr). "
                let bulletAttrs: [NSAttributedString.Key: Any] = [
                    .font: boldFont,
                    .foregroundColor: accentColor
                ]
                let listParagraph = NSMutableParagraphStyle()
                listParagraph.headIndent = baseFontSize * 1.5
                listParagraph.firstLineHeadIndent = baseFontSize * 0.2
                listParagraph.paragraphSpacing = baseFontSize * 0.1
                
                let itemStr = NSMutableAttributedString()
                itemStr.append(NSAttributedString(string: bullet, attributes: bulletAttrs))
                itemStr.append(applyInlineStyles(to: listText, baseAttrs: baseAttrs))
                itemStr.addAttribute(.paragraphStyle, value: listParagraph, range: NSRange(location: 0, length: itemStr.length))
                itemStr.append(NSAttributedString(string: "\n", attributes: baseAttrs))
                result.append(itemStr)
                
                isFirstBlock = false
                i += 1
                continue
            }
            
            // --- Regular paragraph ---
            addSpacingBefore(baseFontSize * 0.3)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = baseFontSize * 0.4
            paragraphStyle.lineSpacing = baseFontSize * 0.2
            
            let paraAttrs = baseAttrs.merging([.paragraphStyle: paragraphStyle]) { _, new in new }
            let styledLine = applyInlineStyles(to: trimmed, baseAttrs: paraAttrs)
            result.append(styledLine)
            result.append(NSAttributedString(string: "\n", attributes: paraAttrs))
            
            isFirstBlock = false
            i += 1
        }
        
        return result
    }
}

