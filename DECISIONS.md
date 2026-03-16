# Technical Decisions

Log of non-obvious technical decisions and their rationale. Newest entries first.

---

## 2026-03-15: Berget Cloud Transcription — API Fixes and Known Server Issue

**Problem**: Berget cloud transcription (`berget-kb-whisper-large`) failed with "API error: Invalid URL" when uploading audio files.

**Client-side fixes applied**:
1. **Removed unsupported form fields**: The original code sent `response_format=verbose_json` and `language` fields. Berget's API only accepts `file` (required) and `model` (optional) — it is NOT fully OpenAI-compatible despite using the same endpoint path.
2. **Fixed MIME types**: Changed from naive `audio/\(pathExtension)` (producing invalid types like `audio/mp3`, `audio/m4a`) to proper MIME mapping (`audio/mpeg`, `audio/mp4`, etc.).
3. **Simplified response parsing**: Berget returns `{"text": "...", "usage": {...}}` — no segments, no language, no duration. Removed dead `parseVerboseResponse()` code.

**Remaining server-side issue**: After all client fixes, the Berget API still returns HTTP 500:
```json
{"error":"Invalid URL","code":"INTERNAL_ERROR","details":{"originalError":{"code":"ERR_INVALID_URL","input":"undefined"}}}
```
The `"input":"undefined"` indicates a Node.js server-side bug where a variable resolves to JavaScript `undefined` and is then passed to a URL constructor. This is not caused by our request — the multipart form data, URL, and auth header are all correct. The API may be temporarily broken or undergoing changes.

**Status**: Waiting for Berget to fix their server. The client code is correct and ready — once the API returns 200, transcription will work.

**Files changed**: `BergetTranscriptionService.swift`.

---

## 2026-03-15: Custom Markdown Renderer for LLM Output

**Problem**: The processed text panel (LLM output) contains markdown with headings (`##`), tables (`| col | col |`), bold, italic, lists, and inline code. Apple's `NSAttributedString(markdown:options: .init(interpretedSyntax: .full))` failed to render headings from LLM streaming output and has zero support for markdown tables.

**Decision**: Replace Apple's markdown parser with a custom line-by-line renderer in `MarkdownTextView.renderMarkdown()`:
- **Headings**: Regex `^#{1,4}\s+` — stripped and styled with bold + scaled font (h1: 1.5x, h2: 1.3x, h3: 1.15x, h4: 1.1x)
- **Tables**: Lines starting with `|` collected as a block. Separator rows (`|---|---|`) filtered out. Header row gets bold + background tint. Columns separated by `│` (Unicode box-drawing character) with dimmed color. A `──┼──` separator line rendered under the header.
- **Unordered lists**: `- `, `* `, `+ ` → green `•` bullet with indentation
- **Ordered lists**: `1. `, `2. ` → green numbered prefix with indentation
- **Horizontal rules**: `---`, `***`, `___` → thin `─` line
- **Inline styles**: `**bold**`/`__bold__`, `*italic*`/`_italic_`, `` `code` `` — applied via regex within any block type
- **Paragraph spacing**: Automatic spacing between blocks using small-font newline spacers

**Why not Apple's parser**: Two issues:
1. `NSAttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace` ignores all block-level elements (headings, lists).
2. With `.full`, headings from LLM streaming output were still not recognized (possibly due to whitespace/encoding differences in streamed text). Tables are not supported at all by Apple's markdown parser.

**Build note**: Xcode MCP tools edit files through the project, but `xcodebuild` uses filesystem timestamps. After editing via MCP, `touch` the file to force recompilation.

**Files changed**: `TranscriptionView.swift` (`MarkdownTextView.renderMarkdown()`).

---

## 2026-03-15: Text Processing Prompts System

**Problem**: The app needs LLM-powered post-processing of transcriptions (summaries, action items, key points). Users need to define and manage the system prompts that control how transcriptions are processed.

**Decision**: Add a `TextProcessingPrompt` data model and full CRUD system in `SettingsManager`:
- **Data model**: `TextProcessingPrompt` struct with `id`, `name`, `prompt`, `createdAt`. Conforms to `Identifiable`, `Codable`, `Equatable`.
- **Storage**: JSON-encoded array in UserDefaults key `textProcessingPrompts`. Manual `loadPrompts()`/`savePrompts()` since `@AppStorage` doesn't support arrays of custom `Codable` types.
- **Default prompts**: 3 Swedish prompts seeded on first launch (Sammanfattning, Åtgärdspunkter, Nyckelpunkter). Reset via `resetToDefaults()`.
- **Settings UI**: New "Bearbeta text" sidebar section with `TextProcessingPromptsView` — expandable inline editor with consistent save/cancel buttons for both new and existing prompts.

**Alternative considered**: Core Data or SwiftData. Rejected — overkill for a small list of prompts. UserDefaults + JSON is sufficient and has no migration complexity.

**Files changed**: `TranscriptionModels.swift`, `SimplifiedManagers.swift`, `SettingsView.swift`, localization strings.

---

## 2026-03-15: LLM Settings Simplification

**Problem**: The LLM settings sections (Ollama local and Berget cloud) had non-functional enable/disable toggles — `@State private var enabledModels` sets were never persisted and did nothing on toggle.

**Decision**: Remove the fake toggles entirely:
- **Ollama**: Show available models with green checkmark icons (read-only). When Ollama is not running, show a link to `ollama.com`.
- **Berget AI**: Replace hardcoded 3-model array with a `BergetLLMModel` struct registry of 5 actual models. Add `@AppStorage("selectedBergetLLMModel")` to `SettingsManager` for future model selection.
- **Localization**: All model section descriptions now use localized keys. Added privacy messaging (local = data stays on device, cloud = GDPR-safe Sweden).

**Files changed**: `SettingsView.swift`, `SimplifiedManagers.swift`, localization strings.

---

## 2026-03-15: Auto-Scroll During Streaming Transcription

**Problem**: When transcribing long audio files, the text would fill the visible area but the view wouldn't scroll to follow new text. Users had to manually scroll down to see the latest transcription output.

**Decision**: Replace the SwiftUI `ScrollView` + `Text` with an `NSViewRepresentable` wrapping `NSScrollView` + `NSTextView` (`AutoScrollingTextView`). On each text update while `isStreaming` is true, call `textView.scrollToEndOfDocument(nil)` — AppKit's native scroll-to-bottom.

**Why not SwiftUI ScrollView?** Two approaches were tried and failed:
1. `ScrollViewReader` + `scrollTo("anchor", anchor: .bottom)` — unreliable with a single large `Text` view (no identifiable sub-views for the proxy to target).
2. `ScrollPosition` + `scrollTo(edge: .bottom)` — doesn't work without `scrollTargetLayout()` and individual identifiable child views.

AppKit's `NSTextView.scrollToEndOfDocument()` works reliably because it operates directly on the underlying scroll view.

**Layout fix**: The `AutoScrollingTextView` (an `NSScrollView`) must NOT be nested inside a SwiftUI `ScrollView`, or the inner scroll view collapses to zero height. The outer `ScrollView` is only used for the empty/progress state.

**Files changed**: `TranscriptionView.swift`.

---

## 2026-03-15: Whisper Leading Space Removal

**Problem**: Every transcription started with a leading space (e.g. " Svensk infrastruktur..."). This is inherent to Whisper's tokenizer — each segment's text includes a leading whitespace character.

**Decision**: Trim whitespace in three places in `WhisperKitService.swift`:
1. `currentWindowText` from `progress.text` in the streaming callback
2. `completedSegments` when saving a finished window
3. Final result segments joined with `.joined(separator: " ")`

All use `.trimmingCharacters(in: .whitespaces)`.

**Files changed**: `WhisperKitService.swift`.

---

## 2026-03-14: Model Download Progress Tracking

**Problem**: When selecting a model that hasn't been downloaded yet, the user had no feedback — just an indefinite spinner while WhisperKit downloaded potentially gigabytes of model files from HuggingFace. No progress bar, no ETA, no indication of what was happening.

**Key discovery**: `WhisperKit.download()` accepts a `progressCallback: ((Progress) -> Void)?` parameter that provides real-time progress with per-file tracking. However, `WhisperKit(config)` internally calls `setupModels()` which calls `download()` **without** forwarding any progress callback — so the API exists but is unreachable through the normal init path.

**Decision**: Split the download phase from the init phase in `WhisperKitService.initialize()`:
1. **Download phase**: Call `WhisperKit.download(variant:downloadBase:from:progressCallback:)` directly with a progress callback that updates `ModelManager.shared`'s published properties.
2. **Load phase**: Pass the resolved folder path to `WhisperKitConfig(modelFolder:, download: false)` → `WhisperKit(config)`. No network calls in this phase.

**Progress hub — ModelManager**: Three `@Published` properties drive UI updates:
- `isDownloading: [String: Bool]` — keyed by model ID
- `downloadProgress: [String: Double]` — 0.0 to 1.0 fraction
- `downloadSpeed: [String: Double]` — bytes/sec from `Progress.userInfo[.throughputKey]`

Also added `modelSizeBytes(for:)` public accessor (the `modelSizes` dict was previously private) so views can compute downloaded-bytes from progress fraction × total size.

**Two UI feedback points**:
- **Model dropdown** (ContentView): When a model is downloading, its row shows `AccentSpinner` + percentage instead of size/download arrow.
- **TranscriptionView**: A full download progress card replaces the generic spinner, showing model name, linear progress bar, "X MB of Y GB", and download speed.

**Alternative considered**: File-system polling (check partial file size vs known total). Rejected because WhisperKit's built-in `Progress` object is more accurate, provides per-file granularity, and includes throughput data.

**Files changed**: `WhisperKitService.swift`, `ModelManager.swift`, `ContentView.swift`, `TranscriptionView.swift`, localization strings.

---

## 2026-03-14: TranscriptionView UI Polish

**Changes**:
- **Back button**: Chevron-only (removed "Back" text label) for a cleaner toolbar.
- **Spinner**: Replaced macOS default `ProgressView()` (AppKit spinning gear) with a custom `AccentSpinner` — a rotating arc using `.primaryAccent` color. Two sizes: 16pt inline (header, streaming indicator) and 32pt centered (progress card).
- **Text tertiary color**: Bumped from `#666666` to `#888888` in dark mode (and `#606065` to `#6E6E75` in light mode) so small metadata labels ("Längd", "Transkriberad tid", "Ord", "Fil", "Format") are readable on dark backgrounds.

**Files changed**: `TranscriptionView.swift`, `ColorExtensions.swift`.

---

## 2026-03-14: Model System Simplification — Remove Enable/Disable Step

**Problem**: Users had to "enable" models in Settings before they appeared in the toolbar dropdown. Many confused enabling with downloading, thinking the toggle would start a download. The extra step added friction without value.

**Decision**: Remove the enable/disable concept entirely:
- **Dropdown shows ALL models always** — 3 sections: KB Whisper (4), Whisper (5), Cloud (Berget, if API key set). Downloaded models show normally; not-yet-downloaded models show size + download arrow icon in dimmed text.
- **Download is lazy** — selecting a not-downloaded model sets it as the active model. Download happens automatically in `WhisperKitService.initialize()` on first transcription attempt.
- **Settings simplified** — "Downloaded Models" section shows only models on disk, with a delete button. "Cloud Models" section shows Berget availability based on API key presence (no toggle).
- **Cloud model auto-visibility** — Berget appears in the dropdown if `settingsManager.bergetKey` is not empty. Removed `@AppStorage("bergetTranscriptionEnabled")`.

**Removed**: `enabledWhisperKitModels` UserDefaults key, `isWhisperKitModelEnabled()`, `toggleWhisperKitModel()`, `loadEnabledWhisperKitModels()`, `saveEnabledWhisperKitModels()`, `WhisperKitModelRow` toggle view.

**Added to ModelManager**: `static let allLocalModels`, `kbModels`, `openAIModels`, `displayNames` dictionary, `displayName(for:)` method.

**Files changed**: `ModelManager.swift`, `ContentView.swift`, `SettingsView.swift`, `WhisperKitService.swift`, `TranscriptionIntegrationHelper.swift`, localization strings.

---

## 2026-03-14: Dark Mode Redesign (Supabase-Inspired)

**Problem**: The app had a light-only UI with hardcoded purple accent colors, a sidebar with search/history that wasn't needed (privacy-focused app, no data saving), and toolbar items were getting grouped into macOS 26's Liquid Glass pill container.

**Decision**: Full visual redesign:
- **Color system**: Replaced all hardcoded colors with adaptive colors using `NSColor(name:dynamicProvider:)`. Green accent (`#3ECF8E`) inspired by Supabase. Dark mode as default.
- **Theme toggle**: `@AppStorage("appColorScheme")` with `"dark"`/`"light"` string values, applied via `.preferredColorScheme()` on the WindowGroup. Toggle button in toolbar.
- **Sidebar removal**: Removed `NavigationSplitView`, search bar, history list, and all related types (`SearchHistoryItem`, `UserProfile`, `addToHistory()`). Single-pane layout.
- **Glass card modifier**: `.glassCard()` ViewModifier using `.ultraThinMaterial` + subtle border for card surfaces.

**Why `NSColor(name:dynamicProvider:)`**: Static `Color` extensions auto-respond to system appearance changes without requiring `@Environment(\.colorScheme)` in every view. The dynamic provider checks the appearance's `bestMatch` against `.darkAqua` / `.aqua`.

**Files changed**: `ColorExtensions.swift` (full rewrite), `TranscribeApp.swift`, `AppState.swift`, `ContentView.swift`, `TranscriptionView.swift`, `RecordingView.swift`, `SettingsView.swift`, `YouTubeTranscriptionView.swift`, localization strings.

---

## 2026-03-14: macOS 26 Toolbar — Right-Alignment and Glass Pill Prevention

**Problem**: macOS 26 groups adjacent toolbar items into a shared Liquid Glass pill container. Also, when using individual `ToolbarItem(placement: .primaryAction)`, items didn't all align to the trailing edge as expected.

**Decision**:
- Use `ToolbarSpacer(.flexible)` as the first toolbar item to push all subsequent items to the right side (pattern from Apple's Landmarks sample).
- Use individual `ToolbarItem` (default placement) with `.sharedBackgroundVisibility(.hidden)` on each to prevent glass pill grouping.
- Also apply `.toolbar(removing: .title)`, `.toolbar(removing: .sidebarToggle)`, and `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`.

**Toolbar order**: language dropdown, model dropdown, theme toggle, settings gear.

**Key API**: `.sharedBackgroundVisibility(.hidden)` — "Hiding the effect will cause the item to be placed in its own grouping" per Apple docs. Available on `ToolbarContent` protocol.

---

## 2026-03-14: Offline-First Model Loading

**Problem**: WhisperKit's default initialization calls `HubApi.getFilenames()` which makes an HTTP GET to `huggingface.co/api/models/...` on every launch, even if models are already downloaded locally. This caused:
1. 5-10 minute delays when models appeared to re-download
2. App failing to start when offline
3. Models stored in `~/Documents/huggingface/` (not cleaned up on app deletion)

**Decision**: Two-phase offline-first loading in `WhisperKitService.initialize()`:
- **Phase 1 (cached)**: Check `ModelManager.cachedModelFolder(for:)`. If path exists on disk, create `WhisperKitConfig(modelFolder: path, download: false)`. Zero network calls.
- **Phase 2 (download)**: Only if no cached path. Download via WhisperKit/Hub, then persist the resolved `kit.modelFolder.path` in UserDefaults for future offline use.

**Storage**: Models now go to `~/Library/Application Support/<bundleID>/Models/HuggingFace/` — proper location that gets cleaned up with the app.

**Persistence**: Model folder paths stored in UserDefaults key `whisperKitModelFolderPaths` as `[String: String]` (modelId -> absolute path). Validated on every app launch.

**Alternative considered**: Using WhisperKit's built-in `HubApi.useOfflineMode`. Rejected because `getFilenames()` is called before `snapshot()` and always requires network, regardless of offline mode setting.

---

## 2026-03-14: Xcode 26 yyjson Linker Error Workaround

**Problem**: Xcode 26 beta defaults `CLANG_COVERAGE_MAPPING` to YES. When building SPM package targets written in pure C (specifically yyjson, a transitive dependency of WhisperKit via swift-transformers → Hub), the coverage instrumentation is added but the linker misses `-fprofile-instr-generate`, leaving `___llvm_profile_runtime` undefined.

**Decision**:
- Added `Transcribe.xcconfig` with `CLANG_COVERAGE_MAPPING = NO`
- Set `ENABLE_CODE_COVERAGE = NO` in both Debug and Release build configurations
- Document that command-line builds need: `xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO`

**Why xcconfig isn't enough**: xcconfig applies to project targets only, not SPM package targets. The setting prevents the issue for our code but yyjson still fails. The xcodebuild flag overrides it globally.

**Root cause**: yyjson is pulled in by swift-transformers (≥1.1.6) Hub target, added in Feb 2026 PR #304. It's a production dependency — cannot be removed without forking swift-transformers.

**Status**: Waiting for Apple to fix the Xcode 26 default or for the SPM build system to inherit project-level settings.

---

## 2026-03-14: macOS 26 (Tahoe) Deployment Target

**Decision**: Updated the Transcribe app target to `MACOSX_DEPLOYMENT_TARGET = 26.0` and Package.swift to `.macOS(.v26)`.

**Note**: The project-level (not target-level) deployment target in the xcodeproj still says `15.5` in the Release config. This is the Xcode project default and is overridden by the target-level setting of `26.0`. The target-level setting is what matters for compilation.

---

## 2026-03-14: KeychainAccess Replaced with Native Security Framework

**Problem**: The `KeychainAccess` SPM package was an unnecessary dependency for simple API key storage.

**Decision**: Replaced with a lightweight `KeychainHelper` enum in `SimplifiedManagers.swift` that wraps the native Security framework (`SecItemCopyMatching`, `SecItemUpdate`, `SecItemAdd`). Uses service name `com.transcribe.api-keys`.

**Migration**: `SettingsManager.init()` checks for a legacy `bergetAPIKey` in UserDefaults and migrates it to Keychain on first launch.

---

## 2026-03-14: Dependency Cleanup

**Removed dependencies** (were in Package.swift but unused or replaced):
- `OllamaKit` — LLM integration not yet implemented
- `OpenAI` / `SwiftOpenAI` — cloud API not actively used
- `Sparkle` — auto-update framework, not configured
- `KeychainAccess` — replaced with native Security framework

**Kept dependencies**:
- `WhisperKit` — core transcription engine
- `YouTubeKit` — YouTube video downloading

---

## Design Principles

These principles guide decisions in this project:

1. **Offline-first**: After initial model download, the app must work without any network access. No phone-home, no API calls to HuggingFace, no telemetry.

2. **Proper file management**: App data goes in `Application Support`, temp files in system temp. Everything gets cleaned up appropriately.

3. **Minimal dependencies**: Prefer native frameworks (Security, AVFoundation) over third-party packages. Every dependency is a maintenance burden and potential build issue.

4. **Privacy**: Transcription happens locally on-device. Cloud transcription (Berget) is opt-in and requires explicit API key configuration.
