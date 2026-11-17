# Technical Decisions

Log of non-obvious technical decisions and their rationale. Newest entries first.

---

## 2026-11-17: Security and Privacy Audit — Pinned Models, Honest Promises

**Context**: The new Help page makes privacy promises, so two independent reviews checked them, and the app's security, against the code and the third-party packages.

**Decisions**:
- **Every model download is pinned to a Hugging Face commit.** This covers Whisper models, their tokenizers and the SpeakerKit diarization models; `ModelRevisions` holds the pins. Before this, they came from each repository's moving `main` branch. Whoever controlled one of those accounts could have shipped new model files to every new install. Parakeet already pinned its downloads and checked SHA-256. `WhisperKit.download` has no revision parameter, so the app makes the same Hub snapshot itself at the pinned commit. There is no fallback to `main`, and an unlisted repository is refused. Integrity for Whisper files is still size-only (the Hub client's check); the immutable commit plus TLS is the protection.
- **Local-only mode is enforced at the network layer**, not only in the UI:
  - The Berget transcription service and `LLMService` refuse while it is on, so turning it on mid-job stops the remaining uploads.
  - Ollama is allowed only at a loopback address. The address is parsed, not prefix-matched: an earlier `hasPrefix("127.")` accepted `127.example.com`.
  - The Ollama connection check is skipped for other computers.
- **The upload to Berget is named `audio.<ext>`**, not the user's file name, which can name the people in the recording.
- **No public logging of file names or paths:**
  - The Parakeet log redacts the file name.
  - WhisperKit/SpeakerKit library logging, which logs everything as public, is on in debug builds only.
  - The diarization debug export, which writes transcript text to Application Support, is compiled out of Release.
- **Quit and close protection now matches the Help text:**
  - A recording made in the app that is not yet transcribed (still running, failed or cancelled) counts as unsaved work. So does an unsaved transcript, including when text processing or speaker names changed it after a save, and an uncopied Quick Transcribe result.
  - The main window cannot be closed while any of these exist; Back and ⌘Q ask instead.
- Removed the dead `enableAnalytics` setting. FluidAudio's leftover `fluidaudio-*.raw` temp files are swept with the app's temp folder.

**Not changed (low)**:
- The legacy UserDefaults API key is removed only after the keychain write succeeds, so it is never lost.
- YouTubeKit's cookies live in the app's container.
- An Ollama address on another computer over `http` is unencrypted; that is the user's choice and is outside local-only mode.

---

## 2026-11-17: Parakeet Word Times — Punctuation Does Not Extend a Word

**Problem**: Speaker labels on Parakeet transcripts put the first words of a turn under the previous speaker ("Hur mycket över" went to the speaker before), even with perfect speaker turns. The cause was in the word times, not the diarizer: TDT emits sentence punctuation late, usually just before the next word, once it can tell the sentence has ended. FluidAudio's `buildWordTimings` ends a word where its last token ends, so "annat." spanned the whole pause after it ([6.96–8.08], speech actually ending at 7.63) and the next word started the instant it ended. `SpeakerTranscriptFormatter` snaps each speaker change to the largest pause between words within ±0.7 s. With the real pause invisible, it snapped to a small pause inside the next sentence.

**Decision**: `ParakeetWords` groups tokens with FluidAudio's word-boundary rule (so the text is identical), but a punctuation-only token joins the word's text without moving its start or end, and confidence is the mean of the spoken tokens. Live text uses the same grouping, since `LiveCommitPolicy` also cuts at pauses between words.

**Rationale**: Fixed at the source rather than by teaching the formatter about Parakeet: segmenting, speaker matching and live commits all read pauses from word times, and Whisper's word times already show them. Verified with opt-in tests: with exact turns every line of a two-voice Swedish dialogue lands on its speaker, and on an English dialogue no speaker label ever holds both voices.

**Known limit (not engine-related)**: the speaker model can split one voice into two labels, or with the count set to 2 merge the wrong ones, on similar synthetic voices. Turns come from the audio alone, so Whisper gets the same turns.

---

## 2026-11-17: Live Transcription — Re-decode the Open Segment

**Problem**: Show text while recording. Pianissimo and Parakeet v3 are not streaming models: they decode one fixed window of up to 15 seconds at a time.

**Approaches considered**:
1. **FluidAudio's `SlidingWindowAsrManager`**: built for this, but it only decodes once a full chunk plus right context (11 + 2 s by default) has been buffered, so the first words arrive after about 13 seconds and then every 11. Its `hypothesisChunkSeconds` setting, which reads as the fix, is never used by the code (FluidAudio 0.18.3). Shrinking the chunk to a second or two is discouraged by its own documentation and multiplies seam errors.
2. **A true streaming model** (FluidAudio also ships Parakeet EOU and Nemotron streaming models): different models with different accuracy; not Pianissimo.
3. **Re-decode the audio since the last commit**: one window decodes in about 130 ms on an M3 Max Neural Engine, so the open segment can simply be decoded again several times a second. **Selected.**

**Decision**: `LiveTranscriptionSession` keeps the samples since the last commit and re-decodes them whenever enough new audio has arrived. Text for that segment is *volatile* (it sharpens as context grows). It becomes *confirmed* when the speaker pauses, or when the segment passes 8 seconds and `LiveCommitPolicy` finds a gap between words that lies at least 2 seconds behind the live edge (the tail of any decode is the part most likely to change); at 12.5 seconds a cut is forced at the best available gap. Decodes are paced so the Neural Engine idles at least twice as long as it works, which makes slower Macs update less often rather than fall behind. Silence is not decoded.

**Why the final pass still runs**: the live text is a preview assembled from overlapping decodes with cuts chosen on the fly. When recording stops, the file is transcribed once more in one batch pass, which gives every window full context and produces the word timestamps the transcript views and speaker assignment need. For a typical recording that pass takes well under a second.

**Measured** (M3 Max, synthesised Swedish speech, 33 s): first words after 1.0 s, 129 ms mean decode, word error rate 2.6 % for both the live text and the batch pass.

**Files**: `LiveTranscriptionSession.swift` (package), `LiveTranscriptController.swift`, `RecordingView.swift`.

---

## 2026-11-17: Parakeet-Family Engine — FluidAudio, Pinned Community CoreML

**Problem**: Add Pianissimo (Klang AI's Swedish fine-tune of NVIDIA Parakeet TDT 0.6B v3) and stock Parakeet v3 as local models.

**Decision**: Run both through FluidAudio (Apache 2.0, CoreML on the Neural Engine), added to TranscribeKit with no package traits so only its ASR code is linked. `ParakeetService` produces the same `TranscriptionUpdate` stream as `WhisperKitService`; `ModelManager.engine(for:)` is the single place that maps a model id to a runtime.

**The Swedish CoreML build is a community conversion.** Klang publishes MLX, ONNX and GGUF builds for Swedish and an official CoreML build only for Danish. The app uses `magnushjelm/pianissimo-sv-coreml`, which has the same component layout. Because that repository is outside our control, `ParakeetModelSpec` pins a commit, and `HuggingFaceDownloader` checks every file against that commit's listed size and SHA-256 before a download is accepted. If Klang publishes official Swedish CoreML, switch the repo and revision there.

**Limits worth knowing**: Parakeet v3 covers 25 European languages and has no Norwegian (NB Whisper remains the Norwegian choice); Pianissimo is Swedish only. The UI warns when the selected language is outside the selected model's set. These models have no language conditioning — the language setting only keeps the decoder in the right script.

**Why only two files import FluidAudio**: its public names (`WordTiming`, `Language`, `TranscriptionResult`, …) collide with WhisperKit's. `ParakeetService.swift` and `LiveTranscriptionSession.swift` are the only files that import it.

---

## 2026-11-17: One Engine for Microphone Capture; Device Bound per Engine

**Problem**: Live transcription needs the samples while recording, which `AVAudioRecorder` never exposes. Separately, the recorder selected its microphone by changing the system-wide default input device and restoring it afterwards — which switched the microphone of every other app (a Teams call on "system default") and stayed changed if the app quit mid-recording.

**Decision**: `MicrophoneCapture` runs one `AVAudioEngine` whose single input tap feeds the level meter, the recording file (`AVAudioFile`, AAC, 48 kHz mono) and the 16 kHz live stream. The device is selected with `kAudioOutputUnitProperty_CurrentDevice` on the engine's own audio unit; the system default is never written. Duration is counted in frames written. The engine is rebuilt on `AVAudioEngineConfigurationChange` so a recording continues when hardware changes.

**The engine starts off the main thread.** Opening the input device talks to the audio server and blocks while macOS shows its microphone-permission dialog; doing it on the main thread froze the window behind that dialog.

**A configuration change re-taps the same engine; it does not build a new one.** A fresh `AVAudioEngine` opens the default input first, so binding another device changes its configuration about 100 ms after it starts, and the engine stops itself. Building a new engine in response repeats that forever — with any non-default microphone nothing was recorded (found by recording from a loopback device; the log showed a new engine every ~150 ms). Both `MicrophoneCapture` and the microphone in `SystemAudioCaptureService` now re-read the input format and re-tap the stopped engine, rebuild only if that fails (device unplugged), cap the number of changes followed in a row, and resume an engine that was already stopped when it was taken over (a change that fired before the observer was attached).

---

## 2026-11-17: Liquid Glass on Controls, Solid Content

**Decision**: Following Apple's guidance for macOS 26/27, Liquid Glass is used for the layer of controls that floats above content — toolbar items (the system's own glass), home tiles, the record button, action buttons — and never for content. Transcripts, cards and settings groups are solid surfaces (`.contentCard()`). The previous `.glassCard()` put a blur material over a flat background, where there was nothing to blur. The brand green appears at scale only in the static backdrop wash and on the single primary action of a screen.

**Revised after the owner's review**: running text has no surface at all. The live-text panel was a grey card with a header and footer rule; against the green backdrop it read as a box from another app, and the owner finds borders and rules cluttered. It now sits directly on the backdrop like the transcript screen does: a status line above, a soft fade where text scrolls out, and a centred empty state until the first words. Cards remain for small grouped content.

**Kept against the guidelines, deliberately**: the toolbar's appearance toggle and Settings button. Apple advises against both on macOS (appearance should follow the system; Settings belongs in the app menu). They are part of this app's established design.

---

## 2026-11-17: NSAudioCaptureUsageDescription Never Reached the Built App

**Finding**: The macOS target generates its Info.plist from build settings; `Transcribe/Info.plist` was never its Info.plist (it was copied into Resources as a plain file), and `NSAudioCaptureUsageDescription` is not a key Xcode generates from an `INFOPLIST_KEY_` setting. The built app therefore had no system-audio usage description at all.

**Why it matters**: ScreenCaptureKit does not need the key, so system audio worked. Core Audio taps do — and the March 2026 entry below records that with taps "the macOS permission prompt never appeared" and callbacks delivered silence. A missing usage description produces exactly that. The key is now merged from `Transcribe-Info.plist`, so taps (audio-only capture, no screen-recording permission or indicator) are worth trying again.

---

## 2026-03-25: Microphone Mixing in System Audio Recording — Ring Buffer Approach

**Problem**: System audio capture (ScreenCaptureKit) only records audio output — remote meeting participants, media, notifications. It does not capture the user's microphone input, which goes directly to the meeting application's network stream. For meeting transcription (Teams, Zoom), users need both sides of the conversation in a single recording.

**Approaches considered**:
1. **AVAudioEngine mixer node**: Route both SCStream audio and mic audio through an AVAudioEngine mixer. Rejected — clock domain conflict between ScreenCaptureKit's callback thread and the hardware audio clock. Scheduling small SCStream buffers on a player node creates timing gaps.
2. **Post-recording merge**: Record system audio and mic to separate files, merge after stopping. Rejected — adds delay after stopping, can't show combined level meter during recording, and startup sync between two independent recordings is fragile.
3. **Manual mixing via ring buffer**: Each source runs independently on its own thread. A thread-safe ring buffer decouples them. The SCStream callback reads mic samples from the ring buffer, mixes with system audio samples, and writes the combined result. **Selected.**

**Decision**: Use a ring buffer to mix mic input into the system audio recording in real-time.

**Architecture**:
- `AudioRingBuffer` — SPSC (single-producer, single-consumer) ring buffer with `os_unfair_lock`. Capacity: ~2 seconds at 48kHz stereo (192,000 floats). Non-interleaved layout `[L0..LN][R0..RN]` matching SCStream format.
- **Mic capture**: `AVAudioEngine` input tap on the default input device. `AVAudioConverter` resamples from mic native format (e.g. 44.1kHz mono) to 48kHz stereo float32 non-interleaved to match SCStream. Converted samples written to ring buffer.
- **Mixing**: In `processAudioBuffer` (SCStream callback), after extracting system audio samples, read matching frame count from ring buffer. Mix via sample-wise addition with clamping to [-1.0, 1.0]. If ring buffer has fewer frames than needed (startup delay, momentary underruns), pad mic with silence.
- **Level meters**: Dual RMS meters — `systemAudioLevel` (green, `.primaryAccent`) and `micLevel` (blue, `.secondaryAccent`) displayed as separate 20-bar meters.
- **Device selection**: CoreAudio device enumeration ported from `RecordingView`'s `AudioRecorderManager`. Users can pick their mic input when mixing is enabled.

**UI**: "Include Microphone" toggle in `SystemAudioRecordingView`, shown before recording starts. When enabled, a mic device picker appears (if multiple inputs available) and dual level meters replace the single meter.

**Files added**: `AudioRingBuffer.swift`
**Files modified**: `SystemAudioCaptureService.swift` (mic engine, converter, ring buffer, mixing in processAudioBuffer, device management), `SystemAudioRecordingView.swift` (toggle, device picker, dual meters, permission handling), `TranscriptionModels.swift` (+`AudioInputDevice` moved from RecordingView), `RecordingView.swift` (removed `AudioInputDevice` definition), localization strings (en + sv)

---

## 2026-03-25: System Audio Capture — ScreenCaptureKit over Core Audio Taps

**Problem**: Users want to transcribe meetings (Teams, Zoom), media playback, and other system audio without routing through a virtual audio device or third-party loopback tool.

**Approaches tried**:
1. **Core Audio Taps API** (macOS 14.2+): `CATapDescription(stereoMixdownOfProcesses: [])` + `AudioHardwareCreateProcessTap()` + aggregate device with tap list. On macOS 26 Tahoe, this approach failed — the macOS permission prompt never appeared, and IO callbacks either delivered all-zero samples or didn't fire at all. Two different wiring approaches were tested (AVAudioEngine input tap, and direct AudioDeviceIOProc), both with the same result.
2. **ScreenCaptureKit** (macOS 13+): `SCStream` with `capturesAudio = true` and minimal video (2x2px, 1fps). This reliably triggered the macOS "Screen & System Audio Recording" permission prompt and delivered real audio data.

**Decision**: Use ScreenCaptureKit for system audio capture.

**Architecture — two-phase capture**:
1. **Monitoring phase** (`startMonitoring()`): Creates `SCStream` on view appear. `SCShareableContent.excludingDesktopWindows()` triggers the permission prompt on first use. Audio callbacks calculate RMS for a live level meter. No file I/O.
2. **Recording phase** (`startCapture()`/`stopCapture()`): Opens an `AVAudioFile` for writing. The same audio callback now also writes buffers to the WAV file.

This separation lets users see the level meter and verify audio is flowing before they start recording.

**Audio format**: ScreenCaptureKit delivers 48kHz stereo float32 non-interleaved audio via `CMSampleBuffer`. Raw data extracted via `CMBlockBufferGetDataPointer` (not `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`, which failed for multi-buffer audio). The WAV is recorded at native format; `AudioPreprocessor` converts to 16kHz mono for WhisperKit at transcription time.

**Permission quirk**: macOS requires the app to quit and relaunch after the user grants "Screen & System Audio Recording" permission. This is standard ScreenCaptureKit behavior.

**Why not Core Audio Taps**: The API is designed for audio-only capture without the screen recording overhead, but on macOS 26 Tahoe it failed to trigger the permission prompt and delivered no usable audio. ScreenCaptureKit's permission flow is well-established and works reliably. The minimal video configuration (2x2px, 1fps) keeps CPU/memory overhead negligible.

**Files added**: `SystemAudioCaptureService.swift`, `SystemAudioRecordingView.swift`
**Files modified**: `AppState.swift` (+`showSystemAudioView`), `ContentView.swift` (navigation + feature card), `Info.plist` (+`NSAudioCaptureUsageDescription`), localization strings (en + sv)

---

## 2026-03-24: Audio Preprocessing for Video Files and Non-Native Formats

**Problem**: Dropping an `.mp4` video file on the app caused a `ExtAudioFileRead` error (CoreAudio code -50). WhisperKit uses `ExtAudioFile` APIs internally, which only support audio containers (WAV, MP3, M4A, etc.) -- not video containers like MP4 or MOV. The local WhisperKit transcription path passed the file directly to WhisperKit without any preprocessing, while the Berget cloud path already used `AudioPreprocessor`.

A user also reported a similar error (-54) with an iPhone Voice Memo (`.m4a`) transferred via iCloud, likely caused by the same underlying issue -- file permissions or iCloud placeholders that `ExtAudioFileRead` couldn't handle.

**Decision**: Add audio preprocessing to the local WhisperKit path in `TranscriptionService.transcribeWithWhisperKit()`:
1. Check `AudioPreprocessor.needsConversionForWhisperKit(url:)` -- returns true for any file extension not in the native audio set (`wav`, `mp3`, `m4a`, `flac`, `aac`, `aif`, `aiff`, `caf`).
2. If conversion needed, call `AudioPreprocessor.extractAudioForWhisperKit(url:)` which extracts the audio track to a temporary 16kHz mono WAV file.
3. Pass the WAV file to WhisperKit instead of the original.
4. Clean up the temporary file after transcription completes.

**Why AVAssetReader/Writer instead of AVAssetExportSession**: The initial fix used `AVAssetExportSession` with `AVAssetExportPresetAppleM4A`, but this preset failed on video containers with a generic "operation could not be completed" error. `AVAssetReader`/`AVAssetWriter` gives full control over reading individual tracks from any container format and writing them in the exact format WhisperKit expects (16kHz, mono, 16-bit PCM).

**Why WAV over M4A**: WhisperKit internally converts all audio to 16kHz mono PCM anyway. Writing WAV directly avoids an unnecessary encode/decode round-trip through AAC and produces exactly the format WhisperKit will use.

**Files changed**: `AudioPreprocessor.swift` (added `needsConversionForWhisperKit()`, `extractAudioForWhisperKit()`, `nativeAudioExtensions`), `TranscriptionService.swift` (added preprocessing step in `transcribeWithWhisperKit()`).

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
