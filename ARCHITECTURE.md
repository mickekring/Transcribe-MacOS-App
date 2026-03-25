# Architecture

Detailed architecture reference for the Transcribe macOS app. For quick-start build instructions, see `CLAUDE.md`.

## App Lifecycle

```
TranscribeApp (@main)
  ├── AppDelegate (NSApplicationDelegate)
  │     ├── Status bar menu (waveform icon)
  │     ├── About / Preferences windows
  │     └── Temp file cleanup on launch + quit
  ├── AppState (navigation, current file)
  ├── TranscriptionManager (transcription queue state)
  └── SettingsManager (AppStorage + Keychain)
```

All three state objects are injected as `@EnvironmentObject` from `TranscribeApp.body`.

## View Hierarchy

```
ContentView (no sidebar — single-pane layout)
  ├── Main content (feature cards: Open Files, Recording, System Audio, YouTube)
  ├── TranscriptionView (active transcription + audio player)
  │     └── AutoScrollingTextView (NSViewRepresentable: NSScrollView + NSTextView, auto-scrolls during streaming)
  ├── RecordingView (mic recording)
  ├── SystemAudioRecordingView (system audio + optional mic mixing)
  └── YouTubeTranscriptionView (URL input + download + transcribe)
```

Toolbar (right-aligned via `ToolbarSpacer(.flexible)`): language dropdown, model dropdown, theme toggle, settings gear. Each item uses `.sharedBackgroundVisibility(.hidden)` to prevent macOS 26 Liquid Glass pill grouping.

### Secondary Windows
- `SettingsView` — SwiftUI Settings scene
- `AboutView` — NSWindow via AppDelegate
- `QuickTranscribeView` — floating NSWindow via status bar menu

## Transcription Pipeline

There are multiple service layers. The primary flow used by the app:

```
TranscriptionView / ContentView
  └── TranscriptionService (routing layer)
        ├── AudioPreprocessor (converts video/non-native formats to WAV)
        └── WhisperKitService (primary engine)
              ├── initialize(modelId:) — offline-first model loading
              ├── transcribe(fileURL:modelId:language:) — AsyncThrowingStream
              └── StreamingCallbackState — accumulates window text for UI
```

### Audio Preprocessing

`TranscriptionService.transcribeWithWhisperKit()` checks `AudioPreprocessor.needsConversionForWhisperKit(url:)` before passing the file to WhisperKit. Native audio formats (WAV, MP3, M4A, FLAC, AAC, AIF, AIFF, CAF) are passed directly. Video containers (MP4, MOV, MKV, etc.) and other formats are extracted to 16kHz mono WAV via `AVAssetReader`/`AVAssetWriter`. The temporary file is cleaned up after transcription.

### WhisperKitService.initialize() Flow

```
1. Check ModelManager.cachedModelFolder(for: modelId)
   ├── HIT:  WhisperKitConfig(modelFolder: path, download: false)
   │         → Zero network calls, loads from disk
   └── MISS: Two-phase download + load
             Phase 1: WhisperKit.download(variant:, progressCallback:)
                      → Downloads from HuggingFace with real-time progress
                      → Updates ModelManager.isDownloading / downloadProgress / downloadSpeed
             Phase 2: WhisperKitConfig(modelFolder: resolvedPath, download: false)
                      → Loads downloaded model, zero network calls
```

After a successful download, the resolved model folder path is persisted in UserDefaults so subsequent launches skip all network access. Download progress is shown in two places: inline percentage in the model dropdown (ContentView) and a full progress card with bar + speed in TranscriptionView.

### Alternative Service Paths (less used)

- `UnifiedTranscriptionService` — wraps WhisperKitService with `TranscriptionServiceProtocol`. Used by some views. Returns `TranscriptionResult` instead of streaming.
- `KBWhisperTranscriptionService` — legacy KB-specific path, uses `cachedModelFolder` for offline loading.
- `BergetTranscriptionService` — cloud transcription via Berget AI API (requires API key). Sends audio to `api.berget.ai/v1`, model `KBLab/kb-whisper-large`.

### TranscriptionService Routing

`TranscriptionService.transcribe(fileURL:)` checks the `selectedTranscriptionModel` AppStorage key:
- `kb_whisper-*` or `openai_whisper-*` → `WhisperKitService`
- `cloud-*` → `transcribeWithCloudModel` (stub)

## Model System

### Model Identifiers

| ID | Repo | Variant | Size |
|----|------|---------|------|
| `kb_whisper-base-coreml` | `mickekringai/kb-whisper-coreml` | `base` | 145 MB |
| `kb_whisper-small-coreml` | `mickekringai/kb-whisper-coreml` | `small` | 483 MB |
| `kb_whisper-medium-coreml` | `mickekringai/kb-whisper-coreml` | `medium` | 1.5 GB |
| `kb_whisper-large-coreml` | `mickekringai/kb-whisper-coreml` | `large` | 3.1 GB |
| `openai_whisper-base` | `argmaxinc/whisperkit-coreml` | `openai_whisper-base` | 145 MB |
| `openai_whisper-small` | `argmaxinc/whisperkit-coreml` | `openai_whisper-small` | 483 MB |
| `openai_whisper-medium` | `argmaxinc/whisperkit-coreml` | `openai_whisper-medium` | 1.5 GB |
| `openai_whisper-large-v2` | `argmaxinc/whisperkit-coreml` | `openai_whisper-large-v2` | 3.1 GB |
| `openai_whisper-large-v3` | `argmaxinc/whisperkit-coreml` | `openai_whisper-large-v3` | 3.1 GB |

KB Whisper models are Swedish-optimized fine-tunes from the Swedish Royal Library (KB), converted to CoreML by the project author.

### ModelManager

Singleton (`ModelManager.shared`). Responsibilities:
- **Model registry**: `static let allLocalModels` — hardcoded list of all 9 model IDs. Also `kbModels` / `openAIModels` filtered subsets and `displayName(for:)` lookup.
- **Storage location**: `~/Library/Application Support/<bundleID>/Models/HuggingFace/`
- **Path persistence**: Model folder paths stored in UserDefaults key `whisperKitModelFolderPaths` (dictionary: modelId → absolute path)
- **Validation**: On init, checks all persisted paths still exist on disk. Removes stale entries.
- **Downloaded tracking**: `@Published var downloadedModels: Set<String>` — derived from persisted paths. No separate "enabled" concept; all models are always visible in the UI.
- **Download progress**: `@Published var isDownloading: [String: Bool]`, `downloadProgress: [String: Double]` (0–1), `downloadSpeed: [String: Double]` (bytes/sec). Written by `WhisperKitService`, read by ContentView and TranscriptionView.
- **Size accessor**: `modelSizeBytes(for:)` — exposes the private `modelSizes` dictionary so views can compute downloaded bytes from progress fraction.
- **Deletion**: Removes both the disk folder and the persisted path entry

### WhisperKit Integration

WhisperKit v0.17.0 (resolved from `from: "0.5.0"` in Package.swift).

Key `WhisperKitConfig` parameters used:
- `modelFolder: String?` — absolute path to skip download entirely
- `downloadBase: URL?` — where HubApi stores downloaded models
- `modelRepo: String?` — HuggingFace repo ID
- `model: String?` — variant name within the repo
- `download: Bool` — whether to allow network downloads

WhisperKit's `modelFolder` property (on the instance) is `URL?` — used to read back the resolved path after download.

## State Management

### Global State (@EnvironmentObject)
- `AppState` — navigation state, current file URL
- `SettingsManager` — all user preferences (AppStorage), API keys (Keychain)
- `TranscriptionManager` — transcription queue progress

### Singletons
- `ModelManager.shared` — model registry, download state, path tracking
- `LanguageManager.shared` — selected transcription language
- `LocalizationManager.shared` — UI language (en/sv)

### Key UserDefaults Keys
| Key | Type | Used By |
|-----|------|---------|
| `selectedTranscriptionModel` | String | ContentView, TranscriptionService |
| `whisperKitModelFolderPaths` | [String: String] | ModelManager |
| `appLanguage` | String | LocalizationManager |
| `appColorScheme` | String ("dark"/"light") | TranscribeApp, ContentView |
| `includeTimestamps` | Bool | WhisperKitService |
| `wordTimestamps` | Bool | WhisperKitService |
| `textProcessingPrompts` | JSON Data | SettingsManager |
| `selectedBergetLLMModel` | String | SettingsManager |

### Keychain
API keys stored via `KeychainHelper` (native Security framework wrapper in `SimplifiedManagers.swift`):
- Service: `com.transcribe.api-keys`
- Key: `bergetAPIKey`

Legacy migration: On first launch of new version, migrates `bergetAPIKey` from UserDefaults to Keychain.

## Text Processing Prompts

User-defined prompts for LLM-based post-processing of transcriptions. Each prompt has a name and body text (used as the system prompt when sending transcriptions to a language model).

### Data Model

`TextProcessingPrompt` in `TranscriptionModels.swift`:
- `id: UUID`, `name: String`, `prompt: String`, `createdAt: Date`
- Conforms to `Identifiable`, `Codable`, `Equatable`

### Storage

Stored in `SettingsManager` (`SimplifiedManagers.swift`):
- `@Published var textProcessingPrompts: [TextProcessingPrompt]`
- Persisted as JSON in UserDefaults key `textProcessingPrompts`
- CRUD methods: `addPrompt(_:)`, `updatePrompt(_:)`, `deletePrompt(_:)`
- Seeds 3 default Swedish prompts on first launch: Sammanfattning, Åtgärdspunkter, Nyckelpunkter

### Settings UI

`TextProcessingPromptsView` in `SettingsView.swift`:
- Located under "Bearbeta text" / "Process Text" sidebar section
- List of prompts with expandable inline editor (name + body)
- Add/edit/delete with consistent save/cancel button pattern

## LLM Service Configuration

### Berget AI (Cloud)

`BergetLLMModel` struct in `SettingsView.swift` with a static registry of 5 models:
- Llama 3.3 70B, Llama 3.1 8B, Mistral Small 3.2 24B, GPT-OSS 120B, GLM 4.7
- Selected model stored in `@AppStorage("selectedBergetLLMModel")` on `SettingsManager`
- Requires Berget API key (same key as cloud transcription)

### Ollama (Local)

Settings show available Ollama models when the local Ollama server is running. If not running, links to `ollama.com` for download.

## File Storage

| Purpose | Location | Lifecycle |
|---------|----------|-----------|
| Models | `~/Library/Application Support/<bundleID>/Models/HuggingFace/` | Persisted, cleaned with app uninstall |
| Recordings | `NSTemporaryDirectory()/Transcribe/` | Cleaned on app launch + quit |
| YouTube downloads | `NSTemporaryDirectory()/Transcribe/` | Cleaned on app launch + quit |

Note: `AppDelegate.cleanupTemporaryFiles()` runs both at `applicationDidFinishLaunching` (catches force-quit leftovers) and `applicationWillTerminate`.

## Dependencies

### Package.swift
- `WhisperKit` (from: "0.5.0") — on-device speech recognition via CoreML
- `YouTubeKit` (from: "0.3.0") — YouTube video downloading

### WhisperKit Transitive Dependencies
```
WhisperKit
  └── swift-transformers (≥1.1.6)
        └── Hub target
              └── yyjson (exact: 0.12.0) — fast JSON parser (C library)
```

The yyjson dependency causes an Xcode 26 build issue — see `DECISIONS.md`.

## Localization

Two-tier system:
1. **UI language** (`LocalizationManager`) — switches between en/sv `.lproj` bundles
2. **Transcription language** (`LanguageManager`) — passed to WhisperKit as decoding option

The `localized(_:)` free function (defined at the bottom of `LanguageManager.swift`) is used throughout views for UI strings.

## Color System

Defined in `ColorExtensions.swift`. All colors use `NSColor(name:dynamicProvider:)` to auto-adapt between dark and light mode without requiring `@Environment(\.colorScheme)`.

### Accent Colors
- `.primaryAccent` — `#3ECF8E` dark / `#2EB57D` light (Supabase green)
- `.secondaryAccent` / `.tertiaryAccent` — darker green variants

### Surface Colors
- `.surfaceBackground` — `#101012` dark / `#FFFFFF` light (main background)
- `.cardBackground` — `#161618` dark / `#F8F8FA` light
- `.elevatedSurface` — `#1E1E20` dark / `#F0F0F2` light

### Text & Chrome
- `.textPrimary` (`#EDEDED` dark) / `.textSecondary` (`#8B8B8B` dark) / `.textTertiary` (`#888888` dark) — text hierarchy
- `.borderLight` / `.hoverBackground` — UI chrome
- `.shadowColor` — adaptive shadow

### Gradients & Modifiers
- `LinearGradient.accentGradient` / `.primaryGradient` / `.cardGradient` — gradient presets
- `.glassCard()` — ViewModifier using `.ultraThinMaterial` + subtle border
- `AccentSpinner` — custom rotating arc spinner in `.primaryAccent` (replaces default macOS `ProgressView`), defined in `ColorExtensions.swift`

## File Map

```
Transcribe/
├── TranscribeApp.swift          — @main entry, scene + environment setup
├── AppDelegate.swift            — NSApplicationDelegate, status bar, cleanup
├── AppState.swift               — Navigation state
├── ContentView.swift            — Main view (no sidebar) + toolbar
├── TranscriptionView.swift      — Active transcription display + audio player
├── RecordingView.swift          — Mic recording UI
├── SystemAudioRecordingView.swift — System audio capture + mic mixing UI
├── YouTubeTranscriptionView.swift — YouTube URL transcription
├── QuickTranscribeView.swift    — Floating quick-transcribe window
├── SettingsView.swift           — Preferences UI
├── AboutView.swift              — About window
│
├── WhisperKitService.swift      — Primary transcription engine (offline-first)
├── TranscriptionService.swift   — Routing layer (model type → service)
├── UnifiedTranscriptionService.swift — Protocol-based wrapper
│
├── ModelManager.swift           — Model storage, path tracking, validation
├── LanguageManager.swift        — Transcription language + TranscriptionLanguage type
├── LocalizationManager.swift    — UI language (en/sv)
├── SimplifiedManagers.swift     — SettingsManager, TranscriptionManager, KeychainHelper
│
├── TranscriptionModels.swift    — Data types (TranscriptionResult, TextProcessingPrompt, AudioInputDevice)
├── ColorExtensions.swift        — Adaptive dark/light colors, glass card modifier
│
├── Services/
│   ├── SystemAudioCaptureService.swift — ScreenCaptureKit system audio + mic mixing
│   ├── AudioRingBuffer.swift    — Thread-safe ring buffer for mic/system audio mixing
│   ├── AudioPreprocessor.swift  — Audio format conversion (video → WAV, resampling)
│   ├── BergetTranscriptionService.swift — Cloud transcription API
│   └── LLMService.swift         — LLM text processing (Berget AI, Ollama)
│
├── YouTubeDownloadService.swift — YouTube audio extraction
│
└── Resources/
    ├── en.lproj/Localizable.strings
    ├── sv.lproj/Localizable.strings
    └── whisper/ (excluded from build)
```
