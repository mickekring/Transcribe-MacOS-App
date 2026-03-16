# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a native macOS SwiftUI app. Open and build with Xcode:

```bash
open Transcribe.xcodeproj
# Build: Cmd+B | Run: Cmd+R
```

The project requires macOS 26+ (Tahoe) and runs on Apple Silicon (M1+).

### Known Xcode 26 Build Issue

Building from Xcode's UI fails with `___llvm_profile_runtime` undefined symbol (yyjson, a pure C SPM transitive dependency of WhisperKit). This is an Xcode 26 bug where `CLANG_COVERAGE_MAPPING` defaults to YES and pure C SPM package targets get coverage instrumentation but miss `-fprofile-instr-generate` in their linker invocation. Build from the command line instead:

```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO
```

**Important**: Always rebuild after making code changes to verify they compile and so the user can test them. Never skip the build step.

## Architecture

### Entry Point
- `Transcribe/TranscribeApp.swift` - Main app with SwiftUI lifecycle
- `Transcribe/AppDelegate.swift` - NSApplicationDelegate for status bar menu, file cleanup, window management

### Core Services

**Transcription Pipeline:**
- `WhisperKitService.swift` - Primary transcription engine using WhisperKit (CoreML). Handles model loading, transcription with progress streaming, and segment generation.
- `UnifiedTranscriptionService.swift` - Routes between local (WhisperKit) and cloud (Berget) services. Manages model state and active service selection.
- `BergetTranscriptionService.swift` - Cloud transcription via Berget AI API (requires API key stored in Keychain)
- `TranscriptionService.swift` - Lightweight streaming wrapper around WhisperKitService

**Audio Processing:**
- `Services/AudioPreprocessor.swift` - Audio format conversion and preprocessing

**LLM Integration:**
- `Services/LLMService.swift` - Text processing via Berget AI or Ollama LLM APIs (summarization, action points, etc.)

**Model Support:**
- KB Whisper models (Swedish-optimized): `kb_whisper-base/small/medium/large-coreml`
- OpenAI Whisper models: `openai_whisper-base/small/medium/large-v2/large-v3`
- Cloud: Berget KB Whisper Large (requires API key)

KB Whisper models load from `mickekringai/kb-whisper-coreml` HuggingFace repo. Default model (`kb_whisper-small-coreml`) auto-downloads on first launch.

### Key Managers
- `ModelManager.swift` - Model downloads, availability checking, and storage management
- `LanguageManager.swift` - Language selection (100+ languages)
- `SimplifiedManagers.swift` - Contains `SettingsManager` (app preferences, API keys, text processing prompts) and `KeychainHelper` (Keychain wrapper for API key storage)
- `LocalizationManager.swift` - UI localization (English/Swedish) via `localized(_:)` helper

### Views
- `ContentView.swift` - Main window with toolbar (file picker, recording, YouTube, settings)
- `TranscriptionView.swift` - Transcription display with audio player, export, and text processing
- `RecordingView.swift` - Built-in audio recording with live level meter, device selector, and playback
- `YouTubeTranscriptionView.swift` - YouTube URL transcription workflow
- `SettingsView.swift` - Preferences with model management, text processing prompts, LLM settings

### Data Models
- `TranscriptionModels.swift` - `TranscriptionResult`, `TranscriptionSegment`, `TextProcessingPrompt`
- `AppState.swift` - Navigation state (`currentTranscriptionURL`, `showTranscriptionView`, `showRecordingView`)

### File Storage & Security
All temporary files auto-cleanup on app quit and on startup (handles force-quit scenarios):
- Recordings: `~/Library/Caches/Transcribe/Recordings/`
- YouTube downloads: `~/Library/Caches/Transcribe/YouTube/`
- Cleanup handled in `AppDelegate.cleanupTemporaryFiles()`

API keys are stored in macOS Keychain via `KeychainHelper` (not UserDefaults). Legacy UserDefaults keys are migrated to Keychain on launch. No `print()` statements in production code — all debug logging has been removed.

## Key Patterns

### State Management
Uses `@EnvironmentObject` for global state:
- `AppState` - Navigation state (current file, view visibility)
- `SettingsManager` - User preferences (persisted via `@AppStorage` and Keychain)
- `TranscriptionManager` - Transcription queue

### Streaming Transcription
WhisperKit provides `AsyncThrowingStream<TranscriptionUpdate, Error>`:
```swift
for try await update in whisperKitService.transcribe(fileURL:modelId:language:) {
    // update.text, update.progress, update.segments, update.isComplete
}
```

### Recording
`RecordingView` contains `AudioRecorderManager` which handles:
- Microphone permission via `AVAudioApplication.shared.recordPermission` (modern API)
- Live audio level metering via `AVAudioEngine` input tap (pre-recording) and `AVAudioRecorder` metering (during recording)
- Audio input device selection via CoreAudio (`AudioObjectGetPropertyData`)
- Proper lifecycle management — engine taps removed before deallocation, no async self capture in `deinit`

### Color System
Adaptive dark/light colors defined in `ColorExtensions.swift` using `NSColor(name:dynamicProvider:)`:
- `.primaryAccent` (`#3ECF8E` green), `.secondaryAccent`, `.tertiaryAccent` - Brand accent
- `.surfaceBackground`, `.cardBackground`, `.elevatedSurface` - Surface hierarchy
- `.textPrimary/Secondary/Tertiary` - Text hierarchy
- `LinearGradient.accentGradient`, `LinearGradient.primaryGradient`
- `.glassCard()` modifier - `ultraThinMaterial` + subtle border

### Theme
- Dark mode default, toggle via toolbar button
- `@AppStorage("appColorScheme")` stores `"dark"` or `"light"`
- Colors auto-adapt via `NSColor` dynamic provider — no `@Environment(\.colorScheme)` needed in views

### Text Processing Prompts
- `TextProcessingPrompt` model in `TranscriptionModels.swift` — `Identifiable`, `Codable`, `Equatable`
- CRUD in `SettingsManager` (`SimplifiedManagers.swift`) — JSON-encoded in UserDefaults
- 3 default Swedish prompts seeded on first launch (Sammanfattning, Åtgärdspunkter, Nyckelpunkter)
- Settings UI: `TextProcessingPromptsView` in `SettingsView.swift` under "Bearbeta text" sidebar section

### LLM Services
- **Berget AI**: 5-model registry (`BergetLLMModel` in `SettingsView.swift`), selected via `@AppStorage("selectedBergetLLMModel")`
- **Ollama**: Local models, links to `ollama.com` when not running
- Service layer: `LLMService.swift` handles API calls for both providers

## Dependencies (Package.swift)

- `WhisperKit` - On-device speech recognition (CoreML)
- `YouTubeKit` - YouTube video downloading

Keychain access uses the native Security framework (`SimplifiedManagers.swift` → `KeychainHelper`).

## Localization

Uses `localized(_:)` helper function (defined in `LocalizationManager.swift`). String files:
- `Transcribe/Resources/en.lproj/Localizable.strings` - English
- `Transcribe/Resources/sv.lproj/Localizable.strings` - Swedish

English is the default locale with full Swedish localization.

## Testing

```bash
# Run from Xcode: Cmd+U
# Or via xcodebuild:
xcodebuild test -scheme Transcribe -destination 'platform=macOS'
```

Test files:
- `TranscribeTests/TranscribeTests.swift`
- `TranscribeUITests/TranscribeUITests.swift`

## Known Issues / Future Work

- `localOnlyMode` setting exists in UI but is not enforced — network calls can still occur when enabled
- `nonisolated(unsafe) static let shared` on `LocalizationManager` suppresses concurrency warnings without fixing thread safety
- YouTubeTranscriptionView UI strings are hardcoded in Swedish (not using `localized()`)
- AppDelegate status bar menu strings are hardcoded in English (not using `localized()`)
