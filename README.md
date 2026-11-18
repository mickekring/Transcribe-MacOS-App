# Transcribe

A native macOS app for speech-to-text transcription. Runs entirely on-device using CoreML (WhisperKit for Whisper models, FluidAudio for Parakeet models) -- no data leaves your machine unless you choose cloud transcription. Optimized for Swedish (KB Whisper) and Norwegian (NB Whisper), but supports 100+ languages.

![Swift](https://img.shields.io/badge/Swift-6.4-orange)
![macOS](https://img.shields.io/badge/macOS-26+-blue)
![License](https://img.shields.io/badge/License-MIT-green)

> [!NOTE]
> **An iOS version (1.1) lives in this repository** as the `TranscribeiOS` target — a full app running KB/NB Whisper, speaker identification, and on-device AI text processing (Gemma 4, Qwen 3.5 via MLX) entirely on the phone. See [iOS version](#ios-version) below, including its hardware requirements.

<img width="1413" height="980" alt="t_3-0-1_1" src="https://github.com/user-attachments/assets/54bda596-99c6-44ae-ac1f-f566afe83585" />

<img width="1413" height="980" alt="t_3-0-1_2" src="https://github.com/user-attachments/assets/611919e8-7b26-40b7-ba10-46e6c3aba1b3" />

<img width="1413" height="980" alt="t_3-0-1_3" src="https://github.com/user-attachments/assets/599224e1-2a31-4b2e-81b7-17f2611fd77f" />

## Features

- **Local transcription** -- WhisperKit runs Whisper models on Apple Silicon via CoreML. No internet required once a model is downloaded. Supports audio files (WAV, MP3, M4A, FLAC, AAC) and video files (MP4, MOV) -- audio is extracted automatically.
- **Swedish-optimized models** -- KB Whisper models from [KBLab](https://huggingface.co/KBLab) (the National Library of Sweden), fine-tuned for Swedish speech.
- **Norwegian-optimized models** -- NB Whisper models from [NbAiLab](https://huggingface.co/NbAiLab) (the National Library of Norway), fine-tuned for Norwegian speech.
- **Live transcription** -- With Pianissimo or Parakeet downloaded, the text appears while you record. It is a preview: when you stop, the whole recording is transcribed again in one pass for the final result.
- **Fast models** -- [Pianissimo](https://klang.ai/pianissimo-sv/) from Klang AI (Swedish) and NVIDIA's Parakeet v3 (25 European languages) transcribe an hour of audio in well under a minute on Apple Silicon.
- **Built-in recording** -- Record directly in the app with a live level meter and input device selection. Choosing a microphone here does not change your system-wide input device.
- **System audio capture** -- Record all audio playing on your Mac (meetings, media, notifications) using ScreenCaptureKit. Optionally mix in your microphone to capture both sides of a meeting. macOS asks for permission on first use.
- **Speaker identification** -- Diarization labels who said what, with renameable speakers and a known-speaker-count control. Runs locally with every local model, Pianissimo and Parakeet included (SpeakerKit/Pyannote), or server-side with cloud transcriptions.
- **Text processing with LLM** -- Summarize, extract action points, or run custom prompts on transcriptions using Berget AI or a local Ollama instance. Speaker-labeled transcripts give the LLM full context of who said what.
- **Cloud transcription (optional)** -- Berget AI provides GDPR-compliant cloud transcription with server-side diarization. Models are listed live from the API (currently KB Whisper, NB Whisper, Pianissimo, and Faster Whisper V3).
- **Privacy by default** -- Recordings and downloaded audio are stored in a temporary cache and automatically deleted when the app quits. The app asks first if a recording hasn't been transcribed or a transcript hasn't been saved.
- **Built-in help** -- The **?** button in the toolbar (or ⌘?) opens a short guide to using the app and to how it handles your data.
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

There is an Xcode bug (still present in Xcode 27.2) where building from the Xcode UI fails with an `___llvm_profile_runtime` undefined symbol error. This is caused by `CLANG_COVERAGE_MAPPING` defaulting to YES, which adds coverage instrumentation to pure-C SPM dependencies (yyjson, a transitive dependency of WhisperKit) without linking the profiling runtime. Build from the command line instead:

```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO
```

The default model (KB Whisper Small) downloads automatically on first launch.

## Models

**Local (on-device):**

| Model | Size | Notes |
| ----- | ---- | ----- |
| Pianissimo | ~630 MB | Swedish. Very fast, accuracy close to KB Whisper Large. Live transcription |
| Parakeet v3 | ~480 MB | 25 European languages (not Norwegian). Very fast. Live transcription |
| KB Whisper Base | ~150 MB | Fast, good for Swedish |
| KB Whisper Small | ~500 MB | Default. Best balance of speed and accuracy for Swedish |
| KB Whisper Medium | ~1.5 GB | Higher accuracy |
| KB Whisper Large | ~3 GB | Highest accuracy |
| NB Whisper Tiny--Large | ~75 MB--3 GB | Norwegian-optimized, four sizes |
| OpenAI Whisper | Base--Large v3 | General multilingual models |

KB Whisper CoreML models are hosted at [mickekringai/kb-whisper-coreml](https://huggingface.co/mickekringai/kb-whisper-coreml) and NB Whisper CoreML models at [digtek/whisperkit-nb-coreml](https://huggingface.co/digtek/whisperkit-nb-coreml) on Hugging Face.

Pianissimo is [Klang AI's](https://huggingface.co/KlangAI/pianissimo-sv) Swedish fine-tune of NVIDIA Parakeet TDT 0.6B v3 (both CC BY 4.0). The app downloads the CoreML conversion at [magnushjelm/pianissimo-sv-coreml](https://huggingface.co/magnushjelm/pianissimo-sv-coreml) and Parakeet v3 from [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), each pinned to a specific revision and checked against its checksums.

Every model download, including the Whisper models, their tokenizers, and the speaker-identification models, is pinned to a specific commit tested with the app. A change to a model repository never reaches the app without a new release.

**Cloud (optional):**

[Berget AI](https://berget.ai) -- Swedish cloud infrastructure, GDPR-compliant. Requires an API key configured in Settings.

## Tech Stack

- **SwiftUI** -- Native macOS interface with Liquid Glass and dark/light mode
- **[WhisperKit and SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift)** -- On-device Whisper models and speaker identification via CoreML
- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** -- On-device Parakeet-family models (Pianissimo, Parakeet v3) via CoreML
- **[YouTubeKit](https://github.com/alexeichhorn/YouTubeKit)** -- YouTube audio downloading
- **AVFoundation / CoreAudio** -- Audio recording, playback, and device management
- **ScreenCaptureKit** -- System audio capture
- **Security.framework** -- API keys stored in macOS Keychain

## Privacy and Security

- With local models, transcription, live text, and speaker identification all happen on your Mac; audio and text never leave it
- **Local-only mode** (Settings → General) switches off everything that could send audio or text off your Mac: cloud transcription and text processing, Ollama at any address other than this computer, the Berget model list, YouTube import, and model downloads. It is enforced where the network requests are made, not just hidden in the interface
- Recordings, YouTube downloads, and converted audio live in a private temporary folder inside the app's sandbox and are deleted on quit; leftovers from force-quits are cleaned up on next launch. The app asks before you leave or quit with a recording that hasn't been transcribed or a transcript that hasn't been saved
- The only network connections the app makes:
  - Hugging Face, for model downloads (the default model downloads automatically on first launch)
  - Berget AI, for cloud transcription and text processing, plus its model list once you've added an API key
  - YouTube, for imports
  - Your own Ollama host
- Audio sent to Berget is uploaded under a neutral file name, never your file's name
- Model downloads are pinned to tested versions (see [Models](#models))
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
