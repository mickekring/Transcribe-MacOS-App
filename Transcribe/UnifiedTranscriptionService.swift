import Foundation
import SwiftUI

/// Unified transcription service that routes between WhisperKit and SwiftWhisper
@MainActor
class UnifiedTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var transcriptionProgress: Double = 0.0
    @Published var currentModel: String?
    @Published var modelState: ModelState = .unloaded
    @Published var errorMessage: String?
    
    // Service instances
    private let whisperKitService = WhisperKitService()
    private lazy var whisperKitWrapper = WhisperKitServiceWrapper(whisperKitService)
    
    // Current active service
    private var activeService: TranscriptionServiceProtocol?
    
    enum ServiceType {
        case whisperKit
    }
    
    enum ModelState {
        case unloaded
        case loading
        case loaded
    }
    
    enum UnifiedError: LocalizedError {
        case noServiceAvailable
        case modelNotFound
        case unsupportedModel
        
        var errorDescription: String? {
            switch self {
            case .noServiceAvailable:
                return "No transcription service available"
            case .modelNotFound:
                return "Model not found"
            case .unsupportedModel:
                return "Unsupported model type"
            }
        }
    }
    
    // MARK: - Model Management
    
    /// Determines which service to use based on model name
    private func getServiceType(for model: String) -> ServiceType {
        // All models now use WhisperKit
        return .whisperKit
    }
    
    /// Load a transcription model
    func loadModel(_ modelName: String) async throws {
        modelState = .loading
        currentModel = nil
        activeService = nil
        errorMessage = nil
        
        do {
            // All models use WhisperKit now
            try await whisperKitService.loadModel(modelName)
            activeService = whisperKitWrapper
            
            currentModel = modelName
            modelState = .loaded
            
        } catch {
            modelState = .unloaded
            activeService = nil
            currentModel = nil
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    /// Unload current model
    func unloadModel() {
        Task {
            await whisperKitService.unloadModel()
        }
        
        activeService = nil
        currentModel = nil
        modelState = .unloaded
        transcriptionProgress = 0.0
    }
    
    /// Check if a model is downloaded
    func isModelDownloaded(_ modelName: String) async -> Bool {
        // WhisperKit handles its own model management
        return await whisperKitService.availableModels.contains(modelName)
    }
    
    /// Download a model
    func downloadModel(_ modelName: String, progressHandler: ((Double) -> Void)? = nil) async throws {
        // WhisperKit downloads models automatically when loading
        try await whisperKitService.loadModel(modelName)
    }
    
    /// Delete a downloaded model
    func deleteModel(_ modelName: String) throws {
        // WhisperKit manages its own model deletion
        // This would need to be implemented in WhisperKitService
    }
    
    // MARK: - Transcription
    
    /// Transcribe audio file
    func transcribe(
        audioURL: URL,
        language: String = "sv",
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        guard let activeService = activeService else {
            throw UnifiedError.noServiceAvailable
        }
        
        isTranscribing = true
        defer { 
            isTranscribing = false
            transcriptionProgress = 0.0
        }
        
        // Update progress
        let progressUpdate: @Sendable (Double) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.transcriptionProgress = progress
                progressHandler?(progress)
            }
        }
        
        // Perform transcription using the active service
        return try await activeService.transcribe(
            audioURL: audioURL,
            language: language,
            progressHandler: progressUpdate
        )
    }
    
    // MARK: - Model Information
    
    /// Get list of all available models
    func getAllAvailableModels() async -> [TranscriptionModel] {
        var models: [TranscriptionModel] = []
        let available = await whisperKitService.availableModels
        
        // KB Whisper CoreML models (WhisperKit)
        let kbCoreMLModels = [
            TranscriptionModel(
                id: "kb_whisper-base-coreml",
                name: "KB Whisper Base",
                size: "145 MB",
                language: "Swedish",
                type: .whisperKit,
                downloaded: available.contains("kb_whisper-base-coreml")
            ),
            TranscriptionModel(
                id: "kb_whisper-small-coreml",
                name: "KB Whisper Small",
                size: "483 MB",
                language: "Swedish",
                type: .whisperKit,
                downloaded: available.contains("kb_whisper-small-coreml")
            )
        ]
        
        // OpenAI Whisper models (WhisperKit)
        let openAIModels = [
            TranscriptionModel(
                id: "openai_whisper-base",
                name: "OpenAI Whisper Base",
                size: "147 MB",
                language: "Multilingual",
                type: .whisperKit,
                downloaded: available.contains("openai_whisper-base")
            ),
            TranscriptionModel(
                id: "openai_whisper-small",
                name: "OpenAI Whisper Small",
                size: "488 MB",
                language: "Multilingual",
                type: .whisperKit,
                downloaded: available.contains("openai_whisper-small")
            ),
            TranscriptionModel(
                id: "openai_whisper-medium",
                name: "OpenAI Whisper Medium",
                size: "1.5 GB",
                language: "Multilingual",
                type: .whisperKit,
                downloaded: available.contains("openai_whisper-medium")
            ),
            TranscriptionModel(
                id: "openai_whisper-large-v2",
                name: "OpenAI Whisper Large v2",
                size: "3.1 GB",
                language: "Multilingual",
                type: .whisperKit,
                downloaded: available.contains("openai_whisper-large-v2")
            ),
            TranscriptionModel(
                id: "openai_whisper-large-v3",
                name: "OpenAI Whisper Large v3",
                size: "3.1 GB",
                language: "Multilingual",
                type: .whisperKit,
                downloaded: available.contains("openai_whisper-large-v3")
            )
        ]
        
        models.append(contentsOf: kbCoreMLModels)
        models.append(contentsOf: openAIModels)
        
        return models
    }
    
    /// Get Swedish-optimized models
    func getSwedishModels() async -> [TranscriptionModel] {
        return await getAllAvailableModels().filter { $0.language == "Swedish" }
    }
    
    /// Get multilingual models
    func getMultilingualModels() async -> [TranscriptionModel] {
        return await getAllAvailableModels().filter { $0.language == "Multilingual" }
    }
}

// MARK: - Protocol for common interface

protocol TranscriptionServiceProtocol {
    func transcribe(
        audioURL: URL,
        language: String,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptionResult
}

// MARK: - Conformance to protocol

// WhisperKit wrapper for protocol conformance
@MainActor
class WhisperKitServiceWrapper: TranscriptionServiceProtocol {
    private let whisperKitService: WhisperKitService
    
    init(_ service: WhisperKitService) {
        self.whisperKitService = service
    }
    
    func transcribe(
        audioURL: URL,
        language: String,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptionResult {
        // Use WhisperKitService's existing transcribe method
        // Collect the streaming updates and return the final result
        var finalText = ""
        var latestText = ""
        var finalSegments: [TranscriptionSegment] = []
        var latestSegments: [TranscriptionSegment] = []
        let currentModelId = await whisperKitService.currentModel
        
        for try await update in whisperKitService.transcribe(
            fileURL: audioURL,
            modelId: currentModelId ?? "openai_whisper-base",
            language: language
        ) {
            progressHandler?(update.progress)
            
            // Always capture the latest text to avoid losing partial results
            if !update.text.isEmpty {
                latestText = update.text
                latestSegments = update.segments.enumerated().map { index, segment in
                    TranscriptionSegment(
                        id: index,
                        start: segment.start,
                        end: segment.end,
                        text: segment.text,
                        confidence: nil,
                        speaker: nil
                    )
                }
            }
            
            if update.isComplete {
                finalText = update.text
                finalSegments = update.segments.enumerated().map { index, segment in
                    TranscriptionSegment(
                        id: index,
                        start: segment.start,
                        end: segment.end,
                        text: segment.text,
                        confidence: nil,
                        speaker: nil
                    )
                }
            }
        }
        
        // Use final text if available, otherwise use the latest captured text
        let resultText = finalText.isEmpty ? latestText : finalText
        let resultSegments = finalSegments.isEmpty ? latestSegments : finalSegments
        
        return TranscriptionResult(
            text: resultText,
            segments: resultSegments,
            language: language,
            duration: resultSegments.last?.end ?? 0,
            timestamp: Date(),
            modelUsed: currentModelId ?? "unknown"
        )
    }
}

// MARK: - Model Information Type

struct TranscriptionModel: Identifiable {
    let id: String
    let name: String
    let size: String
    let language: String
    let type: UnifiedTranscriptionService.ServiceType
    let downloaded: Bool
}