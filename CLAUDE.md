# CLAUDE.md

This file provides guidance to AI coding agents working on this repository.

## Project Overview

VCDR is a minimal macOS menu bar push-to-talk voice transcription app. Hold a global hotkey to record, release to transcribe (via Parakeet/FluidAudio), then execute an action (paste or run a bash command).

**Tech stack:** Swift 6 (strict concurrency), SwiftUI, AVFoundation, CGEvent tap for global hotkeys, FluidAudio (Parakeet v3 CoreML) for transcription.

**Target:** macOS 15.0+ (Sequoia), no App Sandbox.

## Build

```bash
xcodebuild -scheme vcdr -destination 'platform=macOS' build
```

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

## Architecture Rules

These rules exist to prevent specific problems encountered in a previous version of this app. **Do not deviate from them without explicit user approval.**

### 1. No God Objects

**Problem:** The previous version had a 1,019-line `MenuBarController` handling 12+ responsibilities — audio, transcription, window management, hotkeys, UI state, clipboard, text processing, destination routing, focus management, and more. It was untestable and fragile.

**Rule:** No single class should handle more than one major concern. Split responsibilities into focused types:
- `RecordingCoordinator` — orchestration state machine only
- `AudioRecorder` — recording only
- `ParakeetProvider` — transcription only
- `PasteAction`/`BashAction` — post-transcription actions only
- `GlobalHotkeyManager` — hotkey registration only

**Limit:** No class should exceed 300 lines. If it does, it's doing too much — split it.

**Limit:** No class should have more than 5 `@Published`/observable properties. If it does, it's managing too much state.

### 2. No Singletons

**Problem:** The previous version had 7 singletons (`AppSettings.shared`, `ModeManager.shared`, `CaptureHistory.shared`, etc.) with hidden interdependencies, making the code untestable and the dependency graph invisible.

**Rule:** All dependencies must be injected. The only place where objects are created is `AppDependencies.swift`. Every other type receives its dependencies through `init`.

```swift
// GOOD — dependency injection
final class RecordingCoordinator {
    private let settings: AppSettings
    private let transcriptionProvider: any TranscriptionProvider

    init(settings: AppSettings, transcriptionProvider: any TranscriptionProvider) { ... }
}

// BAD — singleton access
final class RecordingCoordinator {
    private let settings = AppSettings.shared  // NEVER do this
}
```

### 3. No Magic Numbers

**Problem:** The previous version had 50+ hardcoded timing values, API defaults, and parameters scattered across files (`0.5`, `0.1`, `2.0`, `50_000_000`, `100_000_000`, etc.) with no explanation of what they represent.

**Rule:** Extract all numeric literals to named constants. Place them as `static let` in a `// MARK: - Constants` section at the top of the relevant type, or in a shared constants enum if used across types.

```swift
// GOOD
private static let clipboardSettleDelay: Duration = .milliseconds(50)
try await Task.sleep(for: Self.clipboardSettleDelay)

// BAD
try await Task.sleep(for: .milliseconds(50))
```

### 4. No print() Statements

**Problem:** The previous version had 227 `print()` statements with emoji prefixes (`📢`, `📦`, `✅`, `❌`) instead of structured logging. These can't be filtered, disabled, or viewed in Console.app.

**Rule:** Always use `OSLog` via the `Logger` extensions in `Logger+Extensions.swift`. Use the appropriate category:

```swift
Logger.app.info("App initialized")
Logger.recording.error("Failed to start recording: \(error)")
Logger.transcription.info("Transcribed in \(elapsed)")
Logger.hotkeys.warning("Hotkey pressed but not idle")
Logger.actions.info("Paste simulated via Cmd+V")
Logger.settings.info("Settings saved")
```

### 5. No Business Logic in Views

**Problem:** The previous version had keyboard handling, validation, and mode switching logic directly in SwiftUI views (`ResultsOverlay`, `CustomModeEditorView`).

**Rule:** Views should only contain layout and binding code. All logic goes into coordinators, actions, or dedicated types. Views call methods on these types — they don't implement the logic themselves.

### 6. Use Swift Concurrency Consistently

**Problem:** The previous version mixed `DispatchQueue.main.asyncAfter` with `Task.sleep` and `@MainActor`, creating inconsistent threading patterns. It also used 7 instances of `Task.sleep` as workarounds for system API timing (window lifecycle, clipboard sync, focus activation).

**Rules:**
- In `@MainActor` or `@Observable` contexts, use `Task.sleep(for:)` instead of `DispatchQueue.main.asyncAfter`
- Use `Task.sleep(for: .milliseconds(N))` syntax, not nanosecond-based `Task.sleep(nanoseconds:)`
- When `Task.sleep` is used as a workaround for a system API (clipboard, focus, window), add a comment explaining *why* the delay is necessary and what it's waiting for
- Prefer polling with timeout over fixed delays when waiting for system state changes (clipboard changeCount, window availability, focus confirmation)

### 7. No Force Unwraps in Production Code

**Problem:** The previous version had force unwraps (`as!`, `!`) in production code paths, risking runtime crashes.

**Rule:** Always use safe unwrapping (`guard let`, `if let`, `as?`). The only acceptable force unwrap is for static constants that are guaranteed valid at compile time (e.g., `URL(string: "https://example.com")!`).

### 8. Protocol-Oriented Abstractions

**What works well:** The previous version's protocol-based design for providers, actions, and destinations was its strongest architectural pattern. This version continues it.

**Rule:** Every major subsystem should have a protocol abstraction:
- `TranscriptionProvider` for speech-to-text backends
- `PostTranscriptionAction` for what happens after transcription
- Any new subsystem (e.g., history, LLM providers) must define a protocol before any concrete implementation

### 9. Proper Resource Cleanup

**Problem:** The previous version had potential memory leaks from timers without `deinit` cleanup and event monitors only cleaned up in `onDisappear`.

**Rule:**
- Any `Timer` must be invalidated in `deinit` or use `Task` with cancellation instead
- Any event monitor (`NSEvent.addLocalMonitorForEvents`, `NSEvent.addGlobalMonitorForEvents`) must have a corresponding removal
- Audio resources (files, sessions) must be cleaned up after use

### 10. Keep Files Focused

**Problem:** The previous version had 7 files over 300 lines, with `SettingsView.swift` at 812 lines containing 7 nested view structs.

**Rule:**
- One primary type per file
- If a view needs helper views, extract them to separate files when they exceed ~50 lines
- Settings tabs should be separate files if the settings UI grows

## Adding New Features

### Adding a New Post-Transcription Action
1. Create a struct conforming to `PostTranscriptionAction` in `Actions/`
2. The action should handle its complete lifecycle (focus restoration, clipboard management, etc.) via init parameters
3. Add a case to `PostTranscriptionActionType` in `AppSettings.swift`
4. Update `RecordingCoordinator.makeAction()` to construct with context (target PID, mode settings)
5. Add UI in `SettingsView` for the new action type

### Adding a New Transcription Provider
1. Create a type conforming to `TranscriptionProvider` in `Transcription/`
2. Wire it through `AppDependencies`
3. The coordinator doesn't need to change — it uses the protocol

### Modifying the Global Hotkey
1. Update `AppSettings` if new settings are needed
2. Update `GlobalHotkeyManager` for registration changes
3. Update `RecordingCoordinator.setupHotkey()` for behavior changes

## Permissions Required

1. **Microphone** — for audio recording (`NSMicrophoneUsageDescription` in Info.plist)
2. **Accessibility** — for global hotkey event tap and simulated paste (Cmd+V via CGEvent)
3. **No App Sandbox** — required for CGEvent tap at `.cgSessionEventTap`

## Things to Watch Out For

- **Clipboard operations may not be instant.** After `NSPasteboard.setString`, add a small delay before simulating Cmd+V. Document the delay with a comment.
- **Focus restoration timing.** After `NSRunningApplication.activate()`, a small delay is needed before sending keyboard events to that app.
- **Parakeet model is large (~1.2GB).** First launch downloads it. Don't assume the model is ready — always check initialization state.
- **CGEvent tap requires accessibility.** The hotkey won't work until the user grants accessibility permissions. Handle this gracefully with polling.
- **Audio recording at 16kHz mono.** This is Parakeet's native format. Don't change the sample rate — it avoids resampling overhead.
