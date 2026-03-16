import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Thread-safe box for Timer references that need to cross Sendable boundaries.
/// Only used for invalidation from completion handlers.
private final class SendableTimerBox: @unchecked Sendable {
    var timer: Timer?
    func invalidate() { timer?.invalidate() }
}

// Custom button style with press animation
struct TranscriptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct TranscriptionView: View {
    @StateObject private var viewModel: TranscriptionViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject private var modelManager = ModelManager.shared
    @State private var showingExportPopover = false
    @State private var displayMode: DisplayMode = .transcript
    @State private var fontSize: Double = 16
    @State private var showTimestamps = false
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
        .navigationBarBackButtonHidden(false)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    if !viewModel.transcribedText.isEmpty && !viewModel.isTranscribing {
                        showUnsavedChangesAlert = true
                    } else {
                        appState.showTranscriptionView = false
                        appState.currentTranscriptionURL = nil
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14))
                        .foregroundColor(.primaryAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .alert(localized("unsaved_transcription"), isPresented: $showUnsavedChangesAlert) {
            Button(localized("copy_and_go_back"), role: nil) {
                viewModel.copyToClipboard()
                appState.showTranscriptionView = false
                appState.currentTranscriptionURL = nil
            }
            Button(localized("go_back_without_saving"), role: nil) {
                appState.showTranscriptionView = false
                appState.currentTranscriptionURL = nil
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
                    let displayText = displayMode == .segments ? formatAsSegments(viewModel.transcribedText) : viewModel.transcribedText
                    
                    AutoScrollingTextView(
                        text: displayText,
                        fontSize: fontSize,
                        isStreaming: viewModel.isTranscribing
                    )
                    
                    if viewModel.isTranscribing {
                        streamingIndicator
                    }
                }
            } else {
                transcriptionProgressView
            }
        }
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
    
    /// Returns the model ID currently being downloaded, if any
    private var activeDownloadModelId: String? {
        modelManager.isDownloading.first(where: { $0.value })?.key
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
                    
                    Text(viewModel.statusMessage.isEmpty ? localized("preparing_audio_file") : viewModel.statusMessage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
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
                    
                    Text(viewModel.statusMessage.isEmpty ? localized("preparing_audio_file") : viewModel.statusMessage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                } else if viewModel.showSingleFileProgress {
                    // Show progress bar for single file transcription
                    VStack(spacing: 16) {
                        Text(viewModel.statusMessage.isEmpty ? localized("transcribing") : viewModel.statusMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.textSecondary)
                        
                        ProgressView(value: viewModel.singleFileProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .tint(Color.primaryAccent)
                            .frame(width: 260)
                            .scaleEffect(y: 2)
                    }
                    
                    Text(viewModel.statusMessage.isEmpty ? localized("preparing_audio_file") : viewModel.statusMessage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                } else {
                    AccentSpinner(size: 32, lineWidth: 3)
                    
                    Text(viewModel.statusMessage.isEmpty ? localized("preparing_audio_file") : viewModel.statusMessage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
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
        VStack(spacing: 0) {
            
            // Main content area
            VStack(alignment: .leading, spacing: 28) {
                // Display Mode Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("display_mode"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 20)
                    
                    HStack(spacing: 8) {
                        Button(action: { displayMode = .transcript }) {
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 13))
                                Text(localized("transcript"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(displayMode == .transcript ? .white : .primaryAccent)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(displayMode == .transcript ? LinearGradient.accentGradient : LinearGradient(colors: [Color.clear], startPoint: .top, endPoint: .bottom))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(LinearGradient.accentGradient, lineWidth: displayMode == .transcript ? 0 : 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        
                        Button(action: { displayMode = .segments }) {
                            HStack(spacing: 6) {
                                Image(systemName: "text.alignleft")
                                    .font(.system(size: 13))
                                Text(localized("segments"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(displayMode == .segments ? .white : .primaryAccent)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(displayMode == .segments ? LinearGradient.accentGradient : LinearGradient(colors: [Color.clear], startPoint: .top, endPoint: .bottom))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(LinearGradient.accentGradient, lineWidth: displayMode == .segments ? 0 : 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                    }
                    .padding(.horizontal, 20)
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
                            .foregroundColor(viewModel.isTranscribing ? .textTertiary : .primaryAccent)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(viewModel.isTranscribing ? Color.white.opacity(0.15) : Color.primaryAccent, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(viewModel.isTranscribing || viewModel.transcribedText.isEmpty)
                        .popover(isPresented: $showingExportPopover) {
                            VStack(alignment: .leading, spacing: 0) {
                                exportPopoverButton(
                                    icon: "doc.text",
                                    label: localized("export_transcription_txt"),
                                    enabled: !viewModel.transcribedText.isEmpty
                                ) {
                                    viewModel.exportTranscriptionAsText()
                                    showingExportPopover = false
                                }
                                
                                exportPopoverButton(
                                    icon: "doc.richtext",
                                    label: localized("export_transcription_md"),
                                    enabled: !viewModel.transcribedText.isEmpty
                                ) {
                                    viewModel.exportTranscriptionAsMarkdown()
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
                        Button(action: { viewModel.copyToClipboard() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13))
                                Text(localized("copy_text"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(viewModel.isTranscribing ? .textTertiary : .primaryAccent)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(viewModel.isTranscribing ? Color.white.opacity(0.15) : Color.primaryAccent, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(viewModel.isTranscribing || viewModel.transcribedText.isEmpty)
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
                        
                        // Show Timestamps Toggle
                        HStack {
                            Text(localized("show_timestamps"))
                                .font(.system(size: 12))
                                .foregroundColor(.textSecondary)
                            
                            Spacer()
                            
                            Toggle("", isOn: $showTimestamps)
                                .toggleStyle(SwitchToggleStyle(tint: .primaryAccent))
                                .labelsHidden()
                        }
                    }
                    .padding(.horizontal, 20)
                }
                
                // Re-transcribe Section
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: { viewModel.retranscribe() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                .font(.system(size: 13))
                            Text(localized("retranscribe"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(viewModel.isTranscribing ? .textTertiary : .primaryAccent)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(viewModel.isTranscribing ? Color.white.opacity(0.15) : Color.primaryAccent, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
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
                            .foregroundColor(sectionDisabled ? .textTertiary : .primaryAccent)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(sectionDisabled ? Color.white.opacity(0.15) : Color.primaryAccent, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
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
                            .foregroundColor(sectionDisabled ? .textTertiary : .primaryAccent)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(sectionDisabled ? Color.white.opacity(0.15) : Color.primaryAccent, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
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
                            .foregroundColor(sectionDisabled ? .textTertiary : .primaryAccent)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(sectionDisabled ? Color.white.opacity(0.15) : Color.primaryAccent, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TranscriptionButtonStyle())
                        .disabled(sectionDisabled)
                        .popover(isPresented: $showLLMPopover) {
                            llmModelPopover
                        }
                        
                        // Process button
                        Button(action: {
                            processTranscription()
                        }) {
                            HStack(spacing: 6) {
                                if isProcessingLLM {
                                    AccentSpinner(size: 13, lineWidth: 1.5)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 13))
                                }
                                Text(isProcessingLLM ? localized("processing_with_llm") : localized("process"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(processButtonDisabled ? .textTertiary : .primaryAccent)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(processButtonDisabled ? Color.white.opacity(0.15) : Color.primaryAccent, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
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
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.surfaceBackground)
            
            // Audio player at bottom
            audioPlayerSection
        }
        .background(Color.surfaceBackground)
    }
    
    var audioPlayerSection: some View {
        VStack(spacing: 8) {
            // Playback controls row
            HStack(spacing: 16) {
                Button(action: { viewModel.skipBackward() }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 18))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.skipForward() }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 18))
                        .foregroundStyle(LinearGradient.accentGradient)
                }
                .buttonStyle(.plain)
                
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
                Slider(value: $viewModel.currentTime, in: 0...viewModel.duration) { editing in
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.cardBackground)
    }
    
    func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
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
    
    func formatAsSegments(_ text: String) -> String {
        // Split text into sentences and add line breaks
        let sentences = text.replacingOccurrences(of: ". ", with: ".\n\n")
                           .replacingOccurrences(of: "! ", with: "!\n\n")
                           .replacingOccurrences(of: "? ", with: "?\n\n")
        return sentences
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
        .onHover { hovering in
            if hovering && enabled {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
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
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    private var sectionDisabled: Bool {
        viewModel.isTranscribing || viewModel.transcribedText.isEmpty
    }
    
    private var processButtonDisabled: Bool {
        sectionDisabled || selectedPromptId == nil || isProcessingLLM || !hasLLMModelSelected
    }
    
    private var hasLLMModelSelected: Bool {
        let provider = settingsManager.preferredLLMProvider
        if provider == "berget" {
            return !settingsManager.bergetKey.isEmpty && !settingsManager.selectedBergetLLMModel.isEmpty
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
            // Find display name from registry
            if let model = LLMCloudModelsView.bergetLLMModels.first(where: { $0.id == settingsManager.selectedBergetLLMModel }) {
                return model.displayName
            }
            return localized("select_model")
        } else {
            if settingsManager.selectedOllamaModel.isEmpty {
                return localized("select_model")
            }
            return settingsManager.selectedOllamaModel
        }
    }
    
    private var llmModelPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Berget section (only if API key configured)
            if !settingsManager.bergetKey.isEmpty {
                Text("Berget AI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                
                ForEach(LLMCloudModelsView.bergetLLMModels) { model in
                    llmPopoverRow(
                        name: model.displayName,
                        subtitle: model.size,
                        isSelected: settingsManager.preferredLLMProvider == "berget" && settingsManager.selectedBergetLLMModel == model.id
                    ) {
                        settingsManager.preferredLLMProvider = "berget"
                        settingsManager.selectedBergetLLMModel = model.id
                        showLLMPopover = false
                    }
                }
            }
            
            // Ollama section (only if models available)
            if !settingsManager.ollamaModels.isEmpty {
                if !settingsManager.bergetKey.isEmpty {
                    Divider().padding(.horizontal, 12).padding(.vertical, 4)
                }
                
                Text("Ollama")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, settingsManager.bergetKey.isEmpty ? 8 : 0)
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
            
            // No models available
            if settingsManager.bergetKey.isEmpty && settingsManager.ollamaModels.isEmpty {
                Text(localized("api_key_required"))
                    .font(.system(size: 12))
                    .foregroundColor(.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
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
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    private func processTranscription() {
        guard let promptId = selectedPromptId,
              let prompt = settingsManager.textProcessingPrompts.first(where: { $0.id == promptId }) else {
            return
        }
        
        // Build system prompt from selected prompt + additional info
        var systemPrompt = prompt.prompt
        if !additionalPromptInfo.isEmpty {
            systemPrompt += "\n\n" + localized("additional_information") + ":\n" + additionalPromptInfo
        }
        
        let transcription = viewModel.transcribedText
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
                    viewModel.processedText += token
                }
            } catch {
                if !Task.isCancelled {
                    viewModel.processedText += "\n\n[Error: \(error.localizedDescription)]"
                }
            }
            
            isProcessingLLM = false
        }
    }
    
    private var selectedPromptName: String {
        if let id = selectedPromptId,
           let prompt = settingsManager.textProcessingPrompts.first(where: { $0.id == id }) {
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

@MainActor
class TranscriptionViewModel: ObservableObject {
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
    @Published var elapsedTime: Double = 0
    @Published var estimatedTimeRemaining: Double = 0
    @Published var errorMessage: String?
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
    @Published var exportErrorMessage = ""
    @Published var processedText = ""
    
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
    
    // Get selected model from UserDefaults
    @AppStorage("selectedTranscriptionModel") private var selectedModel: String = "kb_whisper-small-coreml"
    private var bergetKey: String {
        KeychainHelper.get("bergetAPIKey") ?? ""
    }
    
    init(fileURL: URL) {
        self.fileURL = fileURL
        setupAudioPlayer()
    }
    
    func setupAudioPlayer() {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer?.prepareToPlay()
            audioPlayer?.enableRate = true // Enable rate adjustment
            audioPlayer?.rate = Float(playbackSpeed)
            duration = audioPlayer?.duration ?? 0
        } catch {
            // Audio player setup failed
        }
    }
    
    func retranscribe() {
        // Reset all state for a fresh transcription
        transcribedText = ""
        wordCount = 0
        progress = 0
        segments = []
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
        isTranscribing = true
        // Note: transcription timer starts when actual transcription text arrives,
        // not here — model loading/initialization shouldn't count as transcription time.
        
        // Get selected language
        let selectedLanguage = LanguageManager.shared.selectedLanguage.code == "auto" ? nil : LanguageManager.shared.selectedLanguage.code
        
        // Determine which service to use based on selected model
        if selectedModel == "berget-kb-whisper-large" {
            // Use Berget service
            startBergetTranscription(language: selectedLanguage)
        } else {
            // Use local WhisperKit service
            startLocalTranscription()
        }
    }
    
    private func startLocalTranscription() {
        statusMessage = localized("processing_local_model")
        
        // All local models now use WhisperKit (streaming)
        // This includes OpenAI models and KB CoreML models
        startWhisperKitTranscription()
    }
    
    private func startWhisperKitTranscription() {
        // Original streaming WhisperKit implementation
        transcriptionService = TranscriptionService()
        
        Task {
            do {
                // Stream transcription updates
                for try await update in transcriptionService!.transcribe(fileURL: fileURL) {
                    await MainActor.run {
                        if update.progress < 0.15 && !update.isComplete {
                            // Low-progress updates are status messages (model loading, init, etc.)
                            // Show as status text, don't set as transcribed text
                            self.statusMessage = update.text
                        } else {
                            // Actual transcription content
                            self.transcribedText = update.text
                            self.progress = update.progress
                            self.segments = update.segments
                            self.wordCount = update.text.split(separator: " ").count
                            self.statusMessage = ""
                            
                            // Start transcription timer on first real content
                            if self.transcriptionStartTime == nil {
                                self.transcriptionStartTime = Date()
                                self.transcriptionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                                    if let startTime = self?.transcriptionStartTime {
                                        self?.transcriptionTime = Date().timeIntervalSince(startTime)
                                    }
                                }
                            }
                        }
                        
                        if update.isComplete {
                            self.finishTranscription()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.handleTranscriptionError(error)
                }
            }
        }
    }
    
    private func startBergetTranscription(language: String?) {
        guard !bergetKey.isEmpty else {
            handleTranscriptionError(CloudTranscriptionError.apiError("Berget API key not configured"))
            return
        }
        
        statusMessage = localized("preparing_audio_file")
        bergetService = BergetTranscriptionService(apiKey: bergetKey)
        
        Task {
            do {
                // Preprocess audio
                await MainActor.run {
                    self.isPreprocessing = true
                }
                
                let processedAudio = try await AudioPreprocessor.shared.preprocessAudio(
                    url: fileURL,
                    onProgress: { message in
                        DispatchQueue.main.async {
                            self.statusMessage = message
                        }
                    }
                )
                
                await MainActor.run {
                    self.isPreprocessing = false
                    self.totalChunks = processedAudio.chunks.count
                }
                
                if processedAudio.chunks.count > 1 {
                    // Handle chunked transcription
                    await transcribeChunksWithBerget(processedAudio: processedAudio, language: language)
                } else {
                    // Single file transcription
                    await transcribeSingleFileWithBerget(url: processedAudio.chunks[0].url, language: language)
                }
                
                // Cleanup temporary files
                AudioPreprocessor.shared.cleanupProcessedAudio(processedAudio)
            } catch {
                await MainActor.run {
                    self.handleTranscriptionError(error)
                }
            }
        }
    }
    
    private func transcribeSingleFileWithBerget(url: URL, language: String?) async {
        await MainActor.run {
            self.statusMessage = localized("sending_audio_berget")
            self.showSingleFileProgress = true
            self.singleFileProgress = 0
        }
        
        // Get duration for progress estimation
        let asset = AVAsset(url: url)
        let duration = try? await asset.load(.duration)
        let durationInSeconds = duration != nil ? CMTimeGetSeconds(duration!) : 60.0
        let expectedTime = max(durationInSeconds / 9.0, 2.0) // 9x realtime with minimum 2 seconds
        
        // Start progress timer
        let timerBox = SendableTimerBox()
        await MainActor.run {
            timerBox.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                self.singleFileProgress = min(self.singleFileProgress + (0.1 / expectedTime), 0.95)
            }
        }
        
        bergetService?.transcribe(
            audioURL: url,
            language: language,
            onProgress: { text in
                DispatchQueue.main.async {
                    self.transcribedText = text
                    self.wordCount = text.split(separator: " ").count
                    self.statusMessage = localized("transcribing")
                    self.singleFileProgress = min(self.singleFileProgress, 0.8) // Update progress if we get intermediate results
                }
            },
            completion: { result in
                timerBox.invalidate()
                DispatchQueue.main.async {
                    self.singleFileProgress = 1.0
                    self.showSingleFileProgress = false
                    
                    switch result {
                    case .success(let transcriptionResult):
                        self.transcribedText = transcriptionResult.text
                        self.segments = transcriptionResult.segments.map { segment in
                            TranscriptionSegmentData(
                                start: segment.start,
                                end: segment.end,
                                text: segment.text,
                                words: nil
                            )
                        }
                        self.wordCount = transcriptionResult.text.split(separator: " ").count
                        self.finishTranscription()
                    case .failure(let error):
                        self.handleTranscriptionError(error)
                    }
                }
            }
        )
    }
    
    @MainActor
    private func transcribeChunksWithBerget(processedAudio: AudioPreprocessor.ProcessedAudio, language: String?) async {
        var transcriptionResults: [(chunk: AudioPreprocessor.AudioChunk, result: TranscriptionResult)] = []
        
        // Set flag to indicate we're processing chunks
        self.isProcessingChunks = true
        self.failedChunks = []
        
        for (index, chunk) in processedAudio.chunks.enumerated() {
            self.currentChunk = index + 1
            self.statusMessage = String(format: localized("transcribing_chunk"), index + 1, processedAudio.chunks.count)
            self.chunkProgress = 0
            
            // Start a timer to simulate progress (9x realtime)
            let chunkDuration = chunk.endTime - chunk.startTime
            let expectedTime = chunkDuration / 9.0
            let chunkTimerBox = SendableTimerBox()
            
            chunkTimerBox.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                self.chunkProgress = min(self.chunkProgress + (0.1 / expectedTime), 0.95)
            }
            
            await withCheckedContinuation { continuation in
                bergetService?.transcribe(
                    audioURL: chunk.url,
                    language: language,
                    onProgress: { text in
                        DispatchQueue.main.async {
                            // Update chunk progress
                            self.chunkProgress = 0.5
                        }
                    },
                    completion: { result in
                        chunkTimerBox.invalidate()
                        
                        DispatchQueue.main.async {
                            self.chunkProgress = 1.0
                            
                            switch result {
                            case .success(let transcriptionResult):
                                transcriptionResults.append((chunk: chunk, result: transcriptionResult))
                                
                            case .failure:
                                self.failedChunks.append(index + 1)
                            }
                            
                            continuation.resume()
                        }
                    }
                )
            }
        }
        
        // Merge results
        if !transcriptionResults.isEmpty {
            await MainActor.run {
                self.statusMessage = localized("merging_results")
                
                let mergedResult = AudioPreprocessor.shared.mergeChunkedTranscriptions(transcriptionResults)
                
                if mergedResult.text.isEmpty && transcriptionResults.count > 0 {
                    // Fallback: just concatenate all texts if merge failed
                    self.transcribedText = transcriptionResults.map { $0.result.text }.joined(separator: " ")
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
                
                // Warn about failed chunks
                if !self.failedChunks.isEmpty {
                    let failedList = self.failedChunks.map { String($0) }.joined(separator: ", ")
                    self.transcribedText += "\n\n⚠️ Warning: Chunk(s) \(failedList) of \(processedAudio.chunks.count) failed to transcribe. Some audio may be missing from the result."
                }
                
                self.wordCount = self.transcribedText.split(separator: " ").count
                self.isProcessingChunks = false
                self.finishTranscription()
            }
        } else {
            await MainActor.run {
                self.isProcessingChunks = false
                self.handleTranscriptionError(CloudTranscriptionError.apiError("All \(processedAudio.chunks.count) chunks failed to transcribe. No results received."))
            }
        }
    }
    
    private func finishTranscription() {
        self.isTranscribing = false
        self.estimatedTimeRemaining = 0
        self.transcriptionTimer?.invalidate()
        self.transcriptionTimer = nil
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
    }
    
    private func handleTranscriptionError(_ error: Error) {
        self.isTranscribing = false
        self.errorMessage = error.localizedDescription
        
        // Stop timer on error
        self.transcriptionTimer?.invalidate()
        self.transcriptionTimer = nil
        
        // Reset all progress tracking
        self.currentChunk = 0
        self.totalChunks = 0
        self.chunkProgress = 0
        self.isPreprocessing = false
        self.isProcessingChunks = false
        self.showSingleFileProgress = false
        self.singleFileProgress = 0
        
        // Show error in UI
        let modelName = getModelDisplayName(selectedModel)
        self.transcribedText = """
        ⚠️ Transcription Error
        
        Model: \(modelName)
        Error: \(error.localizedDescription)
        
        Please check:
        1. API key is configured (for cloud models)
        2. Model is downloaded (for local models)
        3. Audio file is valid
        4. Internet connection (for cloud models)
        """
    }
    
    private func getModelDisplayName(_ modelId: String) -> String {
        switch modelId {
        case "berget-kb-whisper-large": return "KB Whisper Large (Berget)"
        default: return modelId
        }
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
        audioPlayer?.currentTime = time
        currentTime = time
    }
    
    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.currentTime = self?.audioPlayer?.currentTime ?? 0
        }
    }
    
    func copyToClipboard() {
        // Copy both transcription and processed text if available
        var combined = transcribedText
        if !processedText.isEmpty {
            combined += "\n\n---\n\n" + processedText
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
    }
    
    private var baseName: String {
        fileName.replacingOccurrences(of: ".\(fileURL.pathExtension)", with: "")
    }
    
    func exportTranscriptionAsText() {
        saveFile(content: transcribedText, defaultName: "\(baseName)_transcription.txt", contentType: .plainText)
    }
    
    func exportTranscriptionAsMarkdown() {
        let md = "# \(fileName)\n\n\(transcribedText)\n"
        saveFile(content: md, defaultName: "\(baseName)_transcription.md", contentType: UTType(filenameExtension: "md") ?? .plainText)
    }
    
    func exportProcessedAsText() {
        saveFile(content: processedText, defaultName: "\(baseName)_processed.txt", contentType: .plainText)
    }
    
    func exportProcessedAsMarkdown() {
        let md = "# \(fileName)\n\n\(processedText)\n"
        saveFile(content: md, defaultName: "\(baseName)_processed.md", contentType: UTType(filenameExtension: "md") ?? .plainText)
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
                } catch {
                    self.exportErrorMessage = error.localizedDescription
                    self.showExportError = true
                }
            }
        }
    }
}

struct TranscriptionSegmentData {
    let start: Double
    let end: Double
    let text: String
    let words: [WordTimestamp]?
}

struct WordTimestamp {
    let word: String
    let start: Double
    let end: Double
    let confidence: Float
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
            
            // Italic: *text* or _text_ (but not inside **)
            let italicPattern = try? NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)|(?<!_)_(?!_)(.+?)(?<!_)_(?!_)")
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

