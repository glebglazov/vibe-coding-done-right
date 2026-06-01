# iOS Architecture Rules

These rules are the iOS copy of the shared VCDR architecture governance. They exist to prevent specific problems encountered in previous versions of the apps. **Do not deviate from them without explicit user approval.**

## 1. No God Objects

**Problem:** Previous versions concentrated recording, transcription, UI state, lifecycle policy, delivery, and settings concerns in oversized coordinators. This made changes risky and the code difficult to test.

**Rule:** No single class should handle more than one major concern. Split responsibilities into focused types:
- `RecordingFlowCoordinator` - orchestration state machine only
- `RecordingRun` - one recording lifecycle only
- `AudioRecorder` - recording only
- `ParakeetProvider` - transcription only
- `HotMicSession` - warm-microphone lifecycle only
- `KeyboardChannelRecordingRunCompletionAdapter` - Keyboard Channel Completion Delivery only

**Limit:** No class should exceed 300 lines. If it does, it's doing too much - split it.

**Limit:** No class should have more than 5 `@Published`/observable properties. If it does, it's managing too much state.

## 2. No Singletons

**Problem:** Previous versions used singletons with hidden interdependencies, making the code untestable and the dependency graph invisible.

**Rule:** All dependencies must be injected. The only place where objects are created is the iOS dependency container. Every other type receives its dependencies through `init`.

```swift
// GOOD - dependency injection
final class RecordingFlowCoordinator {
    private let audioRecorder: AudioRecorder
    private let transcriptionProvider: any TranscriptionProvider

    init(audioRecorder: AudioRecorder, transcriptionProvider: any TranscriptionProvider) { ... }
}

// BAD - singleton access
final class RecordingFlowCoordinator {
    private let audioRecorder = AudioRecorder.shared  // NEVER do this
}
```

## 3. No Magic Numbers

**Problem:** Previous versions scattered hardcoded timing values, API defaults, and parameters across files (`0.5`, `0.1`, `2.0`, `50_000_000`, `100_000_000`, etc.) with no explanation of what they represent.

**Rule:** Extract all numeric literals to named constants. Place them as `static let` in a `// MARK: - Constants` section at the top of the relevant type, or in a shared constants enum if used across types.

```swift
// GOOD
private static let commandAcknowledgementDelay: Duration = .milliseconds(50)
try await Task.sleep(for: Self.commandAcknowledgementDelay)

// BAD
try await Task.sleep(for: .milliseconds(50))
```

## 4. No print() Statements

**Problem:** Previous versions used `print()` statements with emoji prefixes instead of structured logging. These cannot be filtered, disabled, or viewed in Console.app.

**Rule:** Always use `OSLog` via the `Logger` extensions in `Logger+Extensions.swift`. Use the appropriate category:

```swift
Logger.app.info("App initialized")
Logger.recording.error("Failed to start recording: \(error)")
Logger.transcription.info("Transcribed in \(elapsed)")
Logger.ai.warning("AI provider failed, using fallback")
```

## 5. No Business Logic in Views

**Problem:** Previous versions put keyboard handling, validation, and mode-switching logic directly in SwiftUI views.

**Rule:** Views should only contain layout and binding code. All logic goes into coordinators, adapters, or dedicated types. Views call methods on these types - they don't implement the logic themselves.

## 6. Use Swift Concurrency Consistently

**Problem:** Previous versions mixed `DispatchQueue.main.asyncAfter` with `Task.sleep` and `@MainActor`, creating inconsistent threading patterns. They also used `Task.sleep` as workarounds for system API timing.

**Rules:**
- In `@MainActor` or `@Observable` contexts, use `Task.sleep(for:)` instead of `DispatchQueue.main.asyncAfter`
- Use `Task.sleep(for: .milliseconds(N))` syntax, not nanosecond-based `Task.sleep(nanoseconds:)`
- When `Task.sleep` is used as a workaround for a system API (Keyboard Channel propagation, app lifecycle, audio session), add a comment explaining *why* the delay is necessary and what it's waiting for
- Prefer polling with timeout over fixed delays when waiting for system state changes (Keyboard Channel acknowledgement, app availability, audio-session readiness)

## 7. No Force Unwraps in Production Code

**Problem:** Previous versions had force unwraps (`as!`, `!`) in production code paths, risking runtime crashes.

**Rule:** Always use safe unwrapping (`guard let`, `if let`, `as?`). The only acceptable force unwrap is for static constants that are guaranteed valid at compile time (e.g., `URL(string: "vcdr-ios://record")!`).

## 8. Protocol-Oriented Abstractions

**What works well:** The protocol-based design for providers, adapters, and channels keeps major subsystems independently testable. Continue it.

**Rule:** Every major subsystem should have a protocol abstraction:
- `TranscriptionProvider` for speech-to-text backends
- `LLMProvider` for AI backends
- `KeyboardChannelProtocol` for app-group communication with the custom keyboard
- Any new subsystem must define a protocol before any concrete implementation

## 9. Proper Resource Cleanup

**Problem:** Previous versions had potential memory leaks from timers, observers, and audio resources without reliable cleanup.

**Rule:**
- Any `Timer` must be invalidated in `deinit` or use `Task` with cancellation instead
- Any notification observer (`NotificationCenter`, Darwin notifications) must have a corresponding removal
- Any long-lived `Task` must be cancelled when its owner is released
- Audio resources (files, engines, sessions) must be cleaned up after use

## 10. Keep Files Focused

**Problem:** Previous versions had oversized files containing multiple responsibilities and nested view types.

**Rule:**
- One primary type per file
- If a view needs helper views, extract them to separate files when they exceed ~50 lines
- Settings screens should be separate files if the settings UI grows
