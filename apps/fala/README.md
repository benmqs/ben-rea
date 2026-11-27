# Fala (working name)

A macOS menu bar app for voice typing and meeting notes.

- **Dictation:** hold the push-to-talk key (Right Option by default), speak, release.
  Fala transcribes on your Mac with Whisper, polishes the text with Claude, and pastes
  it where your cursor is. If no text field has focus, it copies the text instead.
- **Bubble:** a small black pill sits at the bottom centre of the screen. Click it to dictate
  hands-free (✕ cancels, ✓ finishes and pastes), or right-click it for meetings, Settings and
  Quit. It shows live level bars while listening and a short note above it when something
  needs your attention.
- **Languages:** Portuguese, English and Spanish, or auto-detect.
- **Meetings:** choose **Record a meeting** from the menu bar icon. Fala records your
  microphone and the computer's audio (Zoom, Meet, Teams…) as separate tracks, so the
  transcript can label lines **You** and **Others**. When you stop, it transcribes
  locally, writes notes with Claude (summary, decisions, action items) and opens
  `~/Documents/Fala/Meetings/<date>/notes.md`. The audio files stay in that folder.

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
3. **Screen & System Audio Recording** (asked the first time you record a meeting): allow.
   Fala only uses the audio; it doesn't save any video.

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
| `SystemAudioCapture.swift` | Captures the computer's audio for meetings (ScreenCaptureKit) |
| `MeetingSession.swift` | Meeting folder, audio files, You/Others transcript and notes file |
| `DictationController.swift` | Ties the steps together |

## Known limits

- Without headphones, the mic also picks up the other people, so some of their lines can
  appear twice (once as You). Headphones give the cleanest transcript.
- Push-to-talk dictation is paused while a meeting is recording.
- Long silences on the system-audio track can make Whisper invent a short phrase
  ("Obrigado.", "Thank you."). Voice-activity filtering is a planned improvement.
