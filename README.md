# Transcribe

A native macOS app for speech-to-text transcription. Runs entirely on-device using WhisperKit and CoreML -- no data leaves your machine unless you choose cloud transcription. Optimized for Swedish (KB Whisper) and Norwegian (NB Whisper), but supports 100+ languages.

![Swift](https://img.shields.io/badge/Swift-6.1-orange)
![macOS](https://img.shields.io/badge/macOS-26+-blue)
![License](https://img.shields.io/badge/License-MIT-green)

> [!NOTE]
> **An iOS version (1.1) lives in this repository** as the `TranscribeiOS` target — a full app running KB/NB Whisper, speaker identification, and on-device AI text processing (Gemma 4, Qwen 3.5 via MLX) entirely on the phone. See [iOS version](#ios-version) below, including its hardware requirements.

<img width="2776" height="1860" alt="t26_1" src="https://github.com/user-attachments/assets/0511a227-8a77-4a05-ba39-478eecec5b28" />

<img width="2776" height="1860" alt="t26_2" src="https://github.com/user-attachments/assets/5cb9ace4-92c4-4e36-9f3b-a3a2aa521044" />

## Features

- **Local transcription** -- WhisperKit runs Whisper models on Apple Silicon via CoreML. No internet required once a model is downloaded. Supports audio files (WAV, MP3, M4A, FLAC, AAC) and video files (MP4, MOV) -- audio is extracted automatically.
- **Swedish-optimized models** -- KB Whisper models from [KBLab](https://huggingface.co/KBLab) (the National Library of Sweden), fine-tuned for Swedish speech.
- **Norwegian-optimized models** -- NB Whisper models from [NbAiLab](https://huggingface.co/NbAiLab) (the National Library of Norway), fine-tuned for Norwegian speech.
- **Klang Pianissimo** -- [Klang's](https://klang.ai/pianissimo/) Swedish speech model (a fine-tune of NVIDIA Parakeet TDT 0.6B v3), run on-device via [FluidAudio](https://github.com/FluidInference/FluidAudio). Transcribes well over 100x realtime on Apple Silicon.
- **Live transcription** -- With Klang Pianissimo downloaded, Swedish text appears while you record (microphone or system audio). The recording is still transcribed in full afterwards, with speaker identification.
- **Built-in recording** -- Record directly in the app with live audio level metering and input device selection.
- **System audio capture** -- Record all audio playing on your Mac (meetings, media, notifications) using ScreenCaptureKit. Optionally mix in your microphone to capture both sides of a meeting. macOS asks for permission on first use.
- **Speaker identification** -- Diarization labels who said what, with renameable speakers and a known-speaker-count control. Runs locally (SpeakerKit/Pyannote) or server-side with cloud transcriptions.
- **Text processing with LLM** -- Summarize, extract action points, or run custom prompts on transcriptions using Berget AI or a local Ollama instance. Speaker-labeled transcripts give the LLM full context of who said what.
- **Cloud transcription (optional)** -- Berget AI provides GDPR-compliant cloud transcription (KB Whisper, NB Whisper, Faster Whisper V3) with server-side diarization. Models are listed live from the API.
- **Privacy by default** -- All recordings and downloads are stored in a temporary cache and automatically deleted when the app quits.
- **100+ languages** -- Whisper supports broad multilingual transcription with automatic language detection.
- **Localized UI** -- English, Swedish, and Norwegian, defaulting to your macOS language.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon (M1+)
- 8 GB RAM minimum (16 GB recommended for large models)

## Installation

```bash
git clone https://github.com/mickekring/Transcribe-MacOS-App.git
cd Transcribe-MacOS-App
```

### Building

There is currently an Xcode 26 beta bug where building from the Xcode UI fails with an `___llvm_profile_runtime` undefined symbol error. This is caused by `CLANG_COVERAGE_MAPPING` defaulting to YES, which adds coverage instrumentation to pure-C SPM dependencies (yyjson, a transitive dependency of WhisperKit) without linking the profiling runtime. Build from the command line instead:

```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO
```

The default model (KB Whisper Small) downloads automatically on first launch.

## Models

**Local (on-device):**

| Model | Size | Notes |
| ----- | ---- | ----- |
| KB Whisper Base | ~150 MB | Fast, good for Swedish |
| KB Whisper Small | ~500 MB | Default. Best balance of speed and accuracy for Swedish |
| KB Whisper Medium | ~1.5 GB | Higher accuracy |
| KB Whisper Large | ~3 GB | Highest accuracy |
| NB Whisper Tiny--Large | ~75 MB--3 GB | Norwegian-optimized, four sizes |
| OpenAI Whisper | Base--Large v3 | General multilingual models |
| Klang Pianissimo | ~690 MB | Swedish only. Parakeet-based (FluidAudio, not WhisperKit); powers live transcription |

KB Whisper CoreML models are hosted at [mickekringai/kb-whisper-coreml](https://huggingface.co/mickekringai/kb-whisper-coreml) and NB Whisper CoreML models at [digtek/whisperkit-nb-coreml](https://huggingface.co/digtek/whisperkit-nb-coreml) on Hugging Face.

**Cloud (optional):**

[Berget AI](https://berget.ai) -- Swedish cloud infrastructure, GDPR-compliant. Requires an API key configured in Settings.

## Tech Stack

- **SwiftUI** -- Native macOS interface with dark/light mode
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** -- On-device speech recognition via CoreML
- **[YouTubeKit](https://github.com/alexeichhorn/YouTubeKit)** -- YouTube audio downloading
- **AVFoundation / CoreAudio** -- Audio recording, playback, and device management
- **ScreenCaptureKit** -- System audio capture
- **Security.framework** -- API keys stored in macOS Keychain

## Privacy and Security

- All transcription and speaker identification happens locally by default
- **Local-only mode** (Settings → General) disables every network feature: cloud transcription/text processing, the model catalog, YouTube import, and model downloads — nothing leaves your Mac
- Recordings, YouTube downloads, and converted audio live in a private temporary folder inside the app's sandbox and are deleted on quit; leftovers from force-quits are cleaned up on next launch
- The only network connections the app ever makes, and only when you use those features: HuggingFace (model downloads), Berget AI (cloud transcription/LLM, requires your API key), YouTube (imports), and your own Ollama host
- API keys are stored in the macOS Keychain, not in plaintext
- No analytics, no tracking, no telemetry — in the app or its dependencies

## iOS version

**Transcribe for iOS** (1.1) is a full app in its own right, living in this repository as the `TranscribeiOS` target. It is built on `TranscribeKit` — a local Swift package holding the core both apps share (WhisperKit service, diarization, audio preprocessing, model management, cloud transcription) — so the phone runs the same tuned pipeline as the Mac.

### Features

- **On-device transcription** — KB/NB Whisper on the iPhone's Neural Engine (KB Whisper Small runs at ~15x realtime, Medium at ~5.5x on an iPhone 17 Pro), with the same tuned speaker identification as the Mac app
- **On-device AI text processing** — summaries, action points, and key points generated fully on the phone via MLX: Gemma 4 E2B (~30 tokens/s on an iPhone 17 Pro), Gemma 4 E4B, and Qwen 3.5 4B. Outputs are saved on each transcription, editable in place, and carry their metadata (model, speed, time)
- **Record or import** — built-in recorder with live waveform, pause/resume, and Bluetooth mic support; import any audio/video via the Files picker
- **Library** — transcriptions persist on the phone with speaker renaming, share-sheet export of text or the original audio, Files-app access to recordings, and an info sheet per transcription (model, language, transcription time, realtime factor)
- **Cloud (optional)** — the same Berget AI transcription models as the Mac app with server-side diarization, plus Berget's full LLM catalog for text processing; API key stored in the Keychain
- **Localized** — Swedish, Norwegian, and English UI with dark/light/system themes

### Hardware requirements

The app has **only been tested on an iPhone 17 Pro (12 GB RAM)** and leans hard on modern hardware. Transcription needs Apple silicon with a capable Neural Engine; the on-device language models are the demanding part — model weights are 3–5 GB each, and iOS caps every app's memory at roughly 6 GB regardless of how much the device has, so **the local LLMs (especially Gemma 4 E4B) realistically require a 12 GB iPhone**. On older or lower-RAM devices, cloud transcription and cloud text processing via Berget AI remain available, and expect the first use of each transcription model to spend several minutes building its Neural Engine cache.

### Privacy on iOS

Privacy follows the same principle as the Mac app — nothing leaves the device:

- Transcription and speaker identification run entirely on-device; the only network connection is HuggingFace for model downloads
- Recordings and transcripts are stored locally in the app's sandbox, visible in the Files app under On My iPhone — this is device-local storage and never syncs to iCloud Drive
- Everything the app stores (recordings, transcripts, models, the Neural Engine cache) is **excluded from iCloud and computer backups**, so no audio or text ever reaches Apple's servers — the trade-off being that transcriptions do not restore onto a new phone
- Files at rest are protected by iOS device encryption

**Retention differs from macOS by design**: the Mac app treats audio as temporary and wipes it on quit, since your source files live elsewhere. On the phone, the app is often the only recorder in the room — recordings and transcriptions are kept until you delete them, and deleting a transcription removes its audio file too.

## License

MIT License -- see [LICENSE](LICENSE) for details.

## Authors

**Micke Kring** -- [mickekring.se](https://mickekring.se)

**Claude Code** -- [claude.ai/code](https://claude.ai/code)

## Contributors

**Peter Ljungstrand** -- [github.com/peterljungstrand](https://github.com/peterljungstrand) (NB Whisper models, pause/resume recording across sleep)
