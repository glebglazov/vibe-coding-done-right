# Project Overview

VCDR is a minimal macOS menu bar voice transcription app. Toggle a global hotkey to record, toggle again to transcribe (via the Default Transcription Model), then execute an action (paste or run a bash command).

**Tech stack:** Swift 6 (strict concurrency), SwiftUI, AVFoundation, Carbon `RegisterEventHotKey` for global hotkeys, FluidAudio (Parakeet v3 CoreML) and WhisperKit (large-v3-turbo CoreML) for transcription.

**Target:** macOS 15.0+ (Sequoia), no App Sandbox.

## Build

```bash
xcodebuild -scheme vcdr-mac -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild test -scheme vcdr-mac -destination 'platform=macOS' -quiet
```

One suite, or one test, by name:

```bash
xcodebuild test -scheme vcdr-mac -destination 'platform=macOS' \
  -only-testing:vcdr-macTests/CaptureSessionHotkeyRebindingTests
```

`-quiet` still lets the app's own `os_log` output through, so pipe it through
`grep -vF 'AX capture: no focused element'` if the noise gets in the way, and
grep for `✘` / `Test run with` to read the result.

### Tests must not need a permission grant

The tests run inside their own `VCDR.app` in DerivedData, not the app you
installed. Accessibility and Microphone are granted per app identity, so that
host never inherits a grant from a release build, and re-signing it drops any
grant it did have. A test that reaches a path guarded by `AXIsProcessTrusted()`
therefore fails on every machine sooner or later.

Route around it rather than granting the host: `CaptureSessionTestEnvironment`
points the active Mode at the built-in Copy destination so the paste path (which
simulates Cmd+V through a CGEvent) never runs. Do the same in any new test —
assert against Copy, a bash destination, or the recorded history, never against
a real paste.

Tests run as a hosted unit test bundle inside the app process (`BUNDLE_LOADER`). The app detects `XCTestBundlePath` and skips heavy initialization (CoreML model loading, audio device enumeration) so the test host launches fast.

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
│   ├── TranscriptionProviderRegistry.swift # The models macOS offers, one resident provider each
│   ├── TranscriptionLibrary.swift        # What is installed, what it costs, install and remove
│   ├── TranscriptionModelState.swift     # A model's own state as the Library shows it, and why a removal is refused
│   ├── TranscriptionModelFiles.swift     # An install's size on disk, and its deletion
│   ├── TranscriptionOverride.swift       # A Mode's own model and sparse settings patch, and the one place they are resolved
│   │   # What a model accepts and what it has been told live in
│   │   # Shared/Transcription/: TranscriptionModelCapability, LanguageHint,
│   │   # TranscriptionModelSettings (keyed by model, so they stay its own)
│   ├── ParakeetProvider.swift            # FluidAudio Parakeet implementation (actor)
│   └── WhisperProvider.swift             # WhisperKit large-v3-turbo implementation (actor)
├── Audio/AudioRecorder.swift             # AVFoundation 16kHz mono recording
├── Hotkeys/
│   ├── CarbonHotkeyRegistry.swift        # Claims key combos; survives Secure Input
│   └── SuspendableHotkeyRegistry.swift   # The registry every owner claims through; drops and restores every claim at once
├── Actions/
│   ├── PostTranscriptionAction.swift     # Protocol
│   ├── AccessibilityGrant.swift          # Has the grant? Plus the app's one request for it
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
