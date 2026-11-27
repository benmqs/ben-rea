# Fala (working name)

A macOS menu bar app for voice typing and meeting notes.

- **Dictation:** hold the push-to-talk key (Right Option by default), speak, release.
  Fala transcribes on your Mac with Whisper, polishes the text with Claude, and pastes
  it where your cursor is. If no text field has focus, it copies the text instead.
- **Bubble:** a small pill at the bottom of the screen shows listening (with a live
  level), transcribing, polishing and pasted/copied.
- **Languages:** Portuguese, English and Spanish, or auto-detect.
- **Meetings:** coming next (mic + system audio, transcript and summary).

## Requirements

- Apple Silicon Mac, macOS 14 or later
- Xcode 16 or later (for the Swift toolchain)
- An Anthropic API key for the clean-up step (optional; turn clean-up off to paste raw transcripts)

## Build and run

```bash
cd apps/fala
scripts/build-app.sh
open build/Fala.app
```

On first launch macOS asks for:

1. **Microphone**: allow.
2. **Accessibility** (System Settings > Privacy & Security > Accessibility): turn on Fala.
   This lets Fala see the push-to-talk key in other apps and paste for you.

The first run downloads the Whisper model (about 1.5 GB) from Hugging Face; after that
transcription works offline. Open **Settings…** from the menu bar icon to add your
Anthropic API key, pick the key, language and model, and add names Fala should spell right.

## How it works

| File | Role |
| --- | --- |
| `HotkeyMonitor.swift` | Detects the push-to-talk key going down and up in any app |
| `AudioRecorder.swift` | Captures the mic as 16 kHz mono samples and reports the input level |
| `Transcriber.swift` | Runs Whisper locally through WhisperKit (Core ML) |
| `TextCleaner.swift` | Sends the transcript to the Claude Messages API for clean-up |
| `TextInserter.swift` | Pastes into the focused text field, or copies when there isn't one |
| `Bubble.swift` | The floating status pill |
| `DictationController.swift` | Ties the steps together |
