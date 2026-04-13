# Project Overview

VCDR is a minimal macOS menu bar voice transcription app. Toggle a global hotkey to record, toggle again to transcribe (via Parakeet/FluidAudio), then execute an action (paste or run a bash command).

**Tech stack:** Swift 6 (strict concurrency), SwiftUI, AVFoundation, CGEvent tap for global hotkeys, FluidAudio (Parakeet v3 CoreML) for transcription.

**Target:** macOS 15.0+ (Sequoia), no App Sandbox.

## Build

```bash
xcodebuild -scheme vcdr-mac -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild test -scheme vcdr-mac -destination 'platform=macOS' -quiet
```

Tests run as a hosted unit test bundle inside the app process (`BUNDLE_LOADER`). The app detects `XCTestBundlePath` and skips heavy initialization (CoreML model loading, audio device enumeration, CGEvent taps) so the test host launches fast.

Parallel testing is disabled in the scheme — tests share `UserDefaults` state via `StyleRegistry` and other components.

## Project Structure

```
vcdr/
├── vcdrApp.swift                    # App entry point: MenuBarExtra + Settings window
├── App/AppDependencies.swift        # DI container — all services wired here
├── Core/
│   ├── Logging/Logger+Extensions.swift   # OSLog categories
│   └── Settings/
│       ├── AppSettings.swift             # UserDefaults-backed @Observable settings
│       └── Mode.swift                    # Mode model + text transform pipeline
├── Transcription/
│   ├── TranscriptionProvider.swift       # Protocol
│   └── ParakeetProvider.swift            # FluidAudio Parakeet implementation (actor)
├── Audio/AudioRecorder.swift             # AVFoundation 16kHz mono recording
├── Hotkeys/GlobalHotkeyManager.swift     # CGEvent tap for global hotkeys
├── Actions/
│   ├── PostTranscriptionAction.swift     # Protocol
│   ├── PasteAction.swift                 # Clipboard + focus restore + simulated Cmd+V
│   └── BashAction.swift                  # Shell command + clipboard copy + optional paste
├── Orchestration/
│   ├── RecordingCoordinator.swift    # State machine: idle→recording→transcribing→executing
│   └── CaptureCoordinator.swift      # Capture view lifecycle + submission pipeline
└── UI/
    ├── MenuBarView.swift
    ├── SettingsView.swift
    ├── ShortcutRecorderRow.swift
    ├── CapturePanel.swift            # Unified capture panel (NSPanel controller)
    ├── CaptureView.swift             # Capture SwiftUI view
    ├── CaptureViewModel.swift        # Capture view model
    └── RecordingIndicator.swift      # Floating indicator for quick action mode
```
