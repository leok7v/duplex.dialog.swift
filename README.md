# duplex.dialog.swift

A minimal SwiftUI app demonstrating **full-duplex voice dialog** on iOS and macOS — the device listens and speaks at the same time, with real-time interruption support.

## Overview

The app starts a continuous speech-recognition loop powered by Apple's `SpeechTranscriber` / `SpeechAnalyzer` APIs. Once it hears a complete sentence it echoes the transcript back through `AVSpeechSynthesizer`, sentence by sentence. If the user speaks again while the app is talking the current utterance is cancelled immediately and the listener takes over — true duplex behaviour.

Voice Processing (`AVAudioEngine` VP mode) is used for acoustic echo cancellation, so the microphone does not pick up the speaker output.

## Features

| Feature | Details |
|---|---|
| Continuous speech-to-text | Progressive transcription via `SpeechTranscriber` |
| Interruptible text-to-speech | User speech cancels the current utterance immediately |
| Voice gender picker | Any / Male / Female |
| Speech-rate slider | From `AVSpeechUtteranceMinimumSpeechRate` to `AVSpeechUtteranceMaximumSpeechRate` |
| Pitch slider | 0.5 × – 2.0 × |
| Scrollable transcript log | Labelled `User:` / `Bot:` turns, auto-scrolls to the latest entry |
| Acoustic echo cancellation | Voice Processing enabled on the audio input node |
| Bluetooth A2DP + loud-speaker routing | Configured automatically on iOS |

## Requirements

| Requirement | Version |
|---|---|
| iOS | 26.4 + |
| macOS | 26.4 + |
| Swift | 5.0 + |
| Xcode | 26 + |

Permissions required in your app's `Info.plist`:
- `NSMicrophoneUsageDescription` — microphone access for speech recognition
- `NSSpeechRecognitionUsageDescription` — on-device speech recognition

## Getting Started

1. Clone the repository.
   ```bash
   git clone https://github.com/leok7v/duplex.dialog.swift.git
   ```
2. Open `Dialog.xcodeproj` in Xcode.
3. Select your target device or simulator.
4. Build and run (`⌘R`).
5. Tap **Start Dialog**, grant microphone and speech-recognition permissions, and start talking.

## Project Structure

```
duplex.dialog.swift/
├── TheApp.swift          # @main entry point
├── views/
│   └── ContentView.swift # SwiftUI view — mic icon, transcript log, controls
├── speech/
│   └── STTS.swift        # Speech-to-text + text-to-speech engine (ObservableObject)
├── Assets.xcassets/      # App icon and accent colour
└── Dialog.xcodeproj/     # Xcode project
```

### Key Classes

**`STTS`** (`speech/STTS.swift`) — the core engine:
- Manages the `AVAudioEngine` tap → format conversion → `SpeechAnalyzer` pipeline.
- Publishes `transcript_log`, `is_active`, `is_running`, and `is_speech_detected` to the view.
- Splits the bot response into individual sentences (using `NLTokenizer`) and speaks them one by one.
- Detects user speech mid-utterance and cancels playback immediately.

**`ContentView`** (`views/ContentView.swift`) — the SwiftUI interface:
- Displays a dynamic mic icon (idle / active / speech-detected states).
- Renders the scrollable transcript log.
- Provides voice-gender, speed, and pitch controls.
- Exposes a single **Start / Stop Dialog** button.

## How It Works

```
Microphone
    │
    ▼ AVAudioEngine (Voice Processing enabled)
    │
    ├──► mono extraction + sample-rate conversion
    │
    ▼ AsyncStream<AnalyzerInput>
    │
    ▼ SpeechAnalyzer  ──►  SpeechTranscriber  ──►  result.isFinal ?
                                                        │ yes
                                                        ▼
                                                   respond(to:)
                                                        │
                                                        ▼
                                               NLTokenizer sentences
                                                        │
                                                        ▼
                                               AVSpeechSynthesizer
                                           (interruptible by user speech)
```

## License

See [LICENSE](LICENSE) for details.
