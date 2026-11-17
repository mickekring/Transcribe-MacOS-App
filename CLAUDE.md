# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a native macOS SwiftUI app. Development happens in VS Code with Claude Code as the primary workflow; Xcode stays open only for SwiftUI previews, Interface/view debugging, and signing/archiving.

The project requires macOS 26+ (Tahoe) and runs on Apple Silicon (M1+). It is built with Xcode 27.2 / Swift 6.4 (sources in Swift 5 language mode); APIs that only exist on macOS 27 are used behind `#available`.

### XcodeBuildMCP (primary build/test/run loop)

The XcodeBuildMCP server (v2.6+) is registered at project scope in `.mcp.json` (`npx -y xcodebuildmcp@latest mcp`). Workflows and session defaults are configured in `.xcodebuildmcp/config.yaml` — it enables the `macos`, `project-discovery`, `coverage`, and `debugging` workflows (only `simulator` is enabled by default, which this macOS-only project doesn't need) and sets `Transcribe.xcodeproj` / scheme `Transcribe` as session defaults, so most build/test/run calls need no arguments.

Use its MCP tools as the main loop — write, build, test, run, iterate — instead of raw `xcodebuild` shell commands. Key tool groups for this project (macOS app):

- **macos**: `build`, `build-and-run`, `test`, `clean`, `launch`, `stop`, `get-app-path`, `list-schemes`, `show-build-settings`
- **project-discovery**: `discover-projects`, `list-schemes`, `show-build-settings`, `get-macos-bundle-id`
- **coverage**: `get-coverage-report`, `get-file-coverage` (from xcresult bundles)
- **debugging**: LLDB tools (`attach`, `add-breakpoint`, `stack`, `variables`, `lldb-command`)

Scheme: `Transcribe`. Always pass `CLANG_COVERAGE_MAPPING=NO` as an extra build setting (see Xcode 26 issue below).

**Important**: Always rebuild after making code changes to verify they compile and so the user can test them. Never skip the build step.

**Running next to the installed app**: the installed copy in /Applications is often running and shares the debug build's bundle id, sandbox container and temp folder. Stop only the debug build's process (by PID, the one under DerivedData) — never by app name. `build_run_macos` may report the installed copy's PID.

### Debug hooks (screenshots and end-to-end runs without a microphone)

Debug builds read launch arguments (see `Transcribe/DebugHarness.swift`), passed with the `launch` tool's launch args:

- `-debugScreen recording|systemAudio` opens that screen at launch
- `-debugShowHelp 1` opens the help window; add `-debugHelpScroll record|transcript|privacy` to scroll it; `-appLanguage sv|en|no` picks the language
- `-debugLiveDemo sv|en` records synthesised speech through the real pipeline (meter, file, live text); add `-debugThenTranscribe 1` to continue into the transcript screen
- `-debugTranscribeDemo sv|en` synthesises speech to a file and opens it for transcription
- `-debugRecordSeconds N -debugInputDevice NAME` records the real input device
- `-selectedTranscriptionModel <id>`, `-appColorScheme light|dark` override settings for that run only

### Known Xcode Build Issue (26 and 27)

Default builds fail with `___llvm_profile_runtime` undefined symbol (yyjson, a pure C SPM transitive dependency of WhisperKit). This is an Xcode bug, still present in 27.2, where `CLANG_COVERAGE_MAPPING` defaults to YES and pure C SPM package targets get coverage instrumentation but miss `-fprofile-instr-generate` in their linker invocation. Always disable coverage mapping:

```bash
# CLI fallback if MCP tools are unavailable:
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO
```

With XcodeBuildMCP, pass `CLANG_COVERAGE_MAPPING=NO` via the tool's extra build settings/args parameter on every build and test invocation.

### Xcode (previews, signing, archiving only)

```bash
open Transcribe.xcodeproj
```

Use Xcode's UI for SwiftUI previews, view hierarchy debugging, and Product → Archive for distribution. Don't use it as the compile-test loop.

## Architecture

### Entry Point
- `Transcribe/TranscribeApp.swift` - Main app with SwiftUI lifecycle
- `Transcribe/AppDelegate.swift` - NSApplicationDelegate for status bar menu, file cleanup, window management

### Core Services

**Transcription Pipeline** (shared package, `TranscribeKit/Sources/TranscribeKit/`):
- `ModelManager.swift` - Model catalog, download state and storage. `ModelManager.engine(for:)` is the one place that maps a model id to its runtime (`.whisperKit`, `.parakeet`, `.cloud`); route through it, never by id prefix.
- `TranscriptionService.swift` - Entry point for local transcription: preprocesses the file, then streams `TranscriptionUpdate`s from whichever engine owns the selected model. Also holds `LocalModels` (engine-agnostic download / cancel / prewarm / unload).
- `WhisperKitService.swift` - Whisper models (KB, NB, OpenAI) via WhisperKit.
- `ParakeetService.swift` - Parakeet-family models (Pianissimo, Parakeet v3) via FluidAudio. Same update stream as WhisperKitService. Words are built by `ParakeetWords`, not FluidAudio's `buildWordTimings` (see DECISIONS.md: late punctuation hid the pauses that speaker matching and live commits rely on).
- `LiveTranscriptionSession.swift` - Live text for Parakeet-family models: re-decodes the audio since the last commit a few times per second and commits at pauses (`LiveCommitPolicy`). See DECISIONS.md.
- `Services/HuggingFaceDownloader.swift` - Downloads a model at a pinned commit and verifies every file's size and SHA-256.
- `ModelRevisions.swift` - The pinned Hugging Face commit for every Whisper model, tokenizer and the SpeakerKit models. Downloads refuse an unlisted repository; never fall back to `main`.
- `Services/BergetTranscriptionService.swift` - Cloud transcription via Berget AI API (requires API key stored in Keychain)

Only `ParakeetService.swift` and `LiveTranscriptionSession.swift` may import FluidAudio: its public type names collide with WhisperKit's.

**Audio Processing:**
- `Services/AudioPreprocessor.swift` - Audio format conversion and preprocessing. Automatically extracts audio from video containers (`.mp4`, `.mov`, etc.) and converts non-native formats to 16kHz mono WAV using `AVAssetReader`/`AVAssetWriter`. Used by both local (WhisperKit) and cloud (Berget) transcription paths.

**Microphone Capture:**
- `Services/MicrophoneCapture.swift` - One `AVAudioEngine` whose input tap feeds the level meter, the recording file (AAC, 48 kHz mono) and a 16 kHz stream for live transcription. Binds the chosen device on the engine's own audio unit (never changes the system default input), starts the engine off the main thread, rebuilds it when hardware changes.
- `Services/LiveTranscriptController.swift` - Owns a `LiveTranscriptionSession` for a recording screen and publishes its confirmed/volatile text; buffers audio while the model loads.

**System Audio Capture:**
- `Services/SystemAudioCaptureService.swift` - Captures system audio output using ScreenCaptureKit with optional microphone mixing. Two-phase architecture: monitoring (level meter, permission prompt) and recording (48kHz stereo float32 WAV). Supports mixing mic input via `AVAudioEngine` + `AudioRingBuffer` for meeting recording (both sides of a conversation). Includes CoreAudio device enumeration and selection for mic input.
- `Services/AudioRingBuffer.swift` - Thread-safe SPSC ring buffer using `os_unfair_lock`. Decouples mic capture (AVAudioEngine thread) from system audio capture (SCStream callback thread) during mixed recording.

**LLM Integration:**
- `Services/LLMService.swift` - Text processing via Berget AI or Ollama LLM APIs (summarization, action points, etc.)

**Model Support:**
- Parakeet family (fast; the models that support live transcription): `pianissimo_sv-coreml` (Klang AI, Swedish only), `parakeet_tdt-v3-coreml` (NVIDIA, 25 European languages, no Norwegian)
- KB Whisper models (Swedish-optimized): `kb_whisper-base/small/medium/large-coreml`
- NB Whisper models (Norwegian-optimized): `nb_whisper-tiny/base/small/large-coreml`
- OpenAI Whisper models: `openai_whisper-base/small/medium/large-v2/large-v3`
- Cloud: Berget ASR models fetched dynamically from /v1/models via `BergetModelCatalog` (KB Whisper Large, NB Whisper Large, Faster Whisper V3; requires API key). Cloud results include server-side diarization (speaker turns).

KB Whisper models load from `mickekringai/kb-whisper-coreml` HuggingFace repo. NB Whisper models load from `digtek/whisperkit-nb-coreml` HuggingFace repo. Parakeet-family models are listed in `ParakeetModelSpec` (repo, pinned revision, files, languages); the Swedish Pianissimo CoreML build is a community conversion, hence the pin. Default model (`kb_whisper-small-coreml`) auto-downloads on first launch only.

### Key Managers
- `ModelManager.swift` - Model downloads, availability checking, and storage management
- `LanguageManager.swift` - Language selection (100+ languages)
- `SimplifiedManagers.swift` - Contains `SettingsManager` (app preferences, API keys, text processing prompts) and `KeychainHelper` (Keychain wrapper for API key storage)
- `LocalizationManager.swift` - UI localization (English/Swedish/Norwegian) via `localized(_:)` helper; first launch defaults from the system language

### Views
- `ContentView.swift` - Root of the single main window: toolbar (language menu, model picker, theme, settings), home screen, screen switching, file import and drop (home screen only)
- `DesignSystem.swift` - Shared visual components: `AuroraBackdrop`, `FeatureTile`, `WaveformMeter`, `StatusBadge`, `.prominentAction()`, `.glassAction()`, `Metrics`
- `TranscriptionView.swift` - Transcription display with audio player, export, and text processing
- `RecordingView.swift` - Microphone recording with waveform meter, device menu, playback, and live text (`LiveTranscriptPanel`)
- `SystemAudioRecordingView.swift` - System audio capture with live level meter, record/stop, playback, and transcription
- `YouTubeTranscriptionView.swift` - YouTube URL transcription workflow
- `SettingsView.swift` - Preferences with model management, text processing prompts, LLM settings
- `HelpView.swift` - The help window (toolbar "?", Help menu ⌘?, home footer, status-bar menu): how to use the app and how it handles data, from `help_*` strings. Its privacy claims are checked against the code; when a feature starts using the network, update `help_data_*` in all three languages.

### Data Models
- `TranscriptionModels.swift` - `TranscriptionResult`, `TranscriptionSegment`, `TextProcessingPrompt`, `AudioInputDevice`
- `AppState.swift` - Navigation as one `Screen` value (`.home`, `.recording`, `.systemAudio`, `.transcription(URL)`) plus `unsavedWork`. All route changes go through `navigate(to:)`, which asks before discarding a recording; the app delegate reads the same state to confirm quitting.

### File Storage & Security
All temporary files live under `FileManager.temporaryDirectory/Transcribe/` (inside the sandbox container) and auto-cleanup on app quit and on startup (handles force-quit scenarios):
- Subfolders: `Recordings/`, `QuickRecordings/`, `SystemAudio/`, `YouTube/`, `Preprocessing/`
- Cleanup handled in `AppDelegate.cleanupTemporaryFiles()` (removes the whole `Transcribe/` temp folder)
- Models and the protected ANE cache live under Application Support (user data, intentionally persistent)

`localOnlyMode` (Settings → General) is enforced: it gates the Berget model catalog fetch, cloud transcription/LLM, Ollama at any address that is not this computer (`LLMService.isOnThisComputer`), YouTube, model downloads (WhisperKitService.runDownload), and first-time diarization model downloads. Diarization pins already-downloaded Pyannote models via PyannoteConfig(modelFolder:) so it never touches the network once installed.

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

### Audio Preprocessing
`TranscriptionService` automatically preprocesses files before passing them to WhisperKit:
- **Native formats** (`.wav`, `.mp3`, `.m4a`, `.flac`, `.aac`, `.aif`, `.aiff`, `.caf`) are passed directly
- **Video containers** (`.mp4`, `.mov`, `.mkv`, etc.) and other formats have their audio extracted to 16kHz mono WAV via `AVAssetReader`/`AVAssetWriter`
- Temporary files are cleaned up after transcription completes

### Recording
`RecordingView` uses `MicrophoneCapture`:
- Microphone permission via `AVAudioApplication.shared.recordPermission`; the meter only starts once access is granted, and the request happens when Record is pressed. Never touch `AVAudioEngine.inputNode` on the main thread — it blocks while macOS shows its permission dialog.
- One input tap drives the meter, the file and the live feed; duration is frames written, not wall-clock time
- Device selection via `kAudioOutputUnitProperty_CurrentDevice` on the engine's audio unit; `nil` follows the system default
- Live text: `ParakeetService.liveModelId(selectedModel:languageCode:)` picks the model (the selected one if Parakeet-family, otherwise a downloaded one that covers the language, so live text also works when Whisper does the final pass). The live transcript is a preview; pressing Transcribe runs the full-file pass.

### System Audio Recording
`SystemAudioRecordingView` uses `SystemAudioCaptureService` which wraps ScreenCaptureKit:
- **Permission**: `SCShareableContent.excludingDesktopWindows()` triggers the macOS "Screen & System Audio Recording" prompt on first use. Requires app restart after granting permission.
- **Monitoring**: `SCStream` with `capturesAudio = true` and minimal video (2x2px, 1fps) provides live audio level metering before recording starts.
- **Recording**: Audio buffers from `SCStreamOutput` callbacks written to WAV via `AVAudioFile`. Format: 48kHz stereo float32 non-interleaved (native ScreenCaptureKit output).
- **Mic mixing**: Optional "Include Microphone" toggle mixes mic input with system audio for meeting recording. `AVAudioEngine` captures mic, `AVAudioConverter` resamples to 48kHz stereo, `AudioRingBuffer` decouples the two threads. SCStream callback reads from ring buffer and mixes (sample addition + clamping). Dual level meters show system and mic levels separately.
- **Device selection**: When mic is enabled, CoreAudio device enumeration lets users pick their mic input. Same pattern as `RecordingView`'s `AudioRecorderManager`.
- **Transcription**: Recorded WAV passed to the same pipeline as microphone recordings — `AudioPreprocessor` converts to 16kHz mono for WhisperKit.
- **Entitlements**: Uses `com.apple.security.device.audio-input` (shared with microphone). `NSAudioCaptureUsageDescription` in Info.plist.
- **Temp files**: `~/tmp/Transcribe/SystemAudio/` — cleaned up by existing `AppDelegate.cleanupTemporaryFiles()`.

### Design System
Liquid Glass is for controls that float above content; content is solid. Follow this when adding UI:
- Toolbar items use the system's glass (no custom backgrounds, no `.sharedBackgroundVisibility(.hidden)`). Controls that pick a value (language, model) use `ToolbarChooserLabel` (icon, value, chevron) so they look alike; a `Menu` using it sets `.menuIndicator(.hidden)`
- Buttons: `.prominentAction()` for the single primary action of a screen (tinted glass), `.glassAction()` for the rest; large custom controls use `.glassEffect(.regular.interactive(), in:)`, grouped in a `GlassEffectContainer`
- Running text (the transcript, live text) sits directly on the window background: no card, no grey fill, no divider lines. The owner finds borders and rules cluttered
- Smaller grouped content (settings groups, status cards): `.contentCard()` — never a material or glass
- `AuroraBackdrop` is the only window background; screens do not paint their own
- The app icon is an Icon Composer document, `Transcribe/AppIcon.icon`: a green gradient fill (its own darker gradient in dark mode) and one glass layer, `mic.svg`. The microphone is drawn by hand because SF Symbols may not be used in app icons. Edit it in Icon Composer (in Xcode's Applications) or edit the JSON/SVG directly, and preview every appearance with `ictool AppIcon.icon --export-image --platform macOS --rendition Default|Dark|TintedDark|ClearLight …`

Adaptive colors in `ColorExtensions.swift` (`NSColor(name:dynamicProvider:)`, with Increase Contrast variants):
- `.primaryAccent` - Brand green for accent text, icons and fills (`#3ECF8E` dark, `#17804F` light so it passes 4.5:1 on white)
- `.onAccent` - Anything drawn on a `primaryAccent` fill (dark on the bright dark-mode green, white in light mode). White on the dark-mode green is only 2:1.
- `.brandGreen` - The bright green in both appearances, for glows and meters that carry no text
- `.surfaceBackground`, `.cardBackground`, `.elevatedSurface` - Surface hierarchy
- `.textPrimary/Secondary/Tertiary` - Text hierarchy (all at least 4.5:1)
- `.recordingRed`, `LinearGradient.accentGradient`
- The asset-catalog `AccentColor` (system controls, sidebar selection, switches) is a deeper green (`#1C8A5A` dark, `#17804F` light) so white labels on it stay legible; it is not the same as `.primaryAccent` in dark mode on purpose.

Perpetual animations must check `accessibilityReduceMotion`.

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

## Dependencies

Declared in `TranscribeKit/Package.swift` and the Xcode project; the resolved versions are locked in `Transcribe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, which is committed (force-added; `.gitignore` excludes lock files in general).

- `argmax-oss-swift` (WhisperKit, SpeakerKit) - Whisper transcription and diarization (CoreML)
- `FluidAudio` - Parakeet-family transcription (0.18.x only: pre-1.0, minor versions break API)
- `YouTubeKit` - YouTube audio; update it when YouTube imports break (each release follows YouTube's changes)
- `mlx-swift`, `mlx-swift-lm`, `swift-huggingface` - iOS target only (on-device LLM)

To update: delete the lock file, run `xcodebuild -resolvePackageDependencies`, read the release notes, then run the tests with `RUN_MODEL_TESTS=1` (the Whisper and Parakeet model tests catch changed transcripts). The repo-root `Package.swift` is a stale manifest that only the editor's language server reads; the app does not use it.

Keychain access uses the native Security framework (`SimplifiedManagers.swift` → `KeychainHelper`).

## Localization

Uses the `localized(_:)` helper (defined in `LocalizationManager.swift`), which follows the in-app language setting. The string tables ship in the shared package, so both apps use them:
- `TranscribeKit/Sources/TranscribeKit/Resources/en.lproj/Localizable.strings` - English
- `TranscribeKit/Sources/TranscribeKit/Resources/sv.lproj/Localizable.strings` - Swedish
- `TranscribeKit/Sources/TranscribeKit/Resources/no.lproj/Localizable.strings` - Norwegian (Bokmål)

Every key must exist in all three. Never use `NSLocalizedString(key, comment:)` — it reads the app's main bundle, which has no string tables, and shows the raw key.

The system permission prompts are localized separately in `Transcribe/{en,sv,nb}.lproj/InfoPlist.strings` (they follow the system language). `NSAudioCaptureUsageDescription` comes from `Transcribe-Info.plist` because Xcode cannot generate that key from a build setting.

## Testing

Prefer the XcodeBuildMCP `macos: test` tool (scheme `Transcribe`, with `CLANG_COVERAGE_MAPPING=NO`). CLI fallback:

```bash
xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO
```

Test files (Swift Testing, hosted in the app):
- `TranscribeTests/TranscribeTests.swift` - Model routing, repository-listing validation, transcript segmenting, the live commit policy, Parakeet word timings, that all three string tables have the same keys
- `TranscribeTests/ParakeetIntegrationTests.swift` - End-to-end against the real models (batch, an AAC recording over 30 s, live, silence, speaker matching). Opt-in: set `RUN_MODEL_TESTS=1` in the test-runner environment. Downloads the models on first run; synthesises its speech with the system voices.
- `TranscribeTests/WhisperIntegrationTests.swift` - KB Whisper Small on synthesised Swedish (same opt-in; skipped if that model is not downloaded), and that every pinned model commit (`ModelRevisions`) still holds its files. Guards WhisperKit, tokenizer and pin updates.
- `TranscribeUITests/TranscribeUITests.swift`

The app's own log lines are readable with `/usr/bin/log show --last 5m --info --predicate 'subsystem BEGINSWITH "com.mickekring.transcribe"'` (zsh has a `log` builtin; use the full path).

## Known Issues / Future Work

- `nonisolated(unsafe) static let shared` on `LocalizationManager` suppresses concurrency warnings without fixing thread safety
- YouTubeTranscriptionView UI strings are hardcoded in Swedish (not using `localized()`)
- AppDelegate status bar menu strings are hardcoded in English (not using `localized()`)
