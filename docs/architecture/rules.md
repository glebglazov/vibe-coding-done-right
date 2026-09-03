# Architecture Rules

These rules exist to prevent specific problems encountered in a previous version of this app. **Do not deviate from them without explicit user approval.**

## 1. No God Objects

**Problem:** The previous version had a 1,019-line `MenuBarController` handling 12+ responsibilities — audio, transcription, window management, hotkeys, UI state, clipboard, text processing, destination routing, focus management, and more. It was untestable and fragile.

**Rule:** No single class should handle more than one major concern. Split responsibilities into focused types:
- `RecordingCoordinator` — orchestration state machine only
- `AudioRecorder` — recording only
- `ParakeetProvider` — transcription only
- `PasteAction`/`BashAction` — post-transcription actions only
- `GlobalHotkeyManager` — hotkey registration only

**Limit:** No class should exceed 300 lines. If it does, it's doing too much — split it.

**Limit:** No class should have more than 5 `@Published`/observable properties. If it does, it's managing too much state.

## 2. No Singletons

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

## 3. No Magic Numbers

**Problem:** The previous version had 50+ hardcoded timing values, API defaults, and parameters scattered across files (`0.5`, `0.1`, `2.0`, `50_000_000`, `100_000_000`, etc.) with no explanation of what they represent.

**Rule:** Extract all numeric literals to named constants. Place them as `static let` in a `// MARK: - Constants` section at the top of the relevant type, or in a shared constants enum if used across types.

```swift
// GOOD
private static let clipboardSettleDelay: Duration = .milliseconds(50)
try await Task.sleep(for: Self.clipboardSettleDelay)

// BAD
try await Task.sleep(for: .milliseconds(50))
```

## 4. No print() Statements

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

## 5. No Business Logic in Views

**Problem:** The previous version had keyboard handling, validation, and mode switching logic directly in SwiftUI views (`ResultsOverlay`, `CustomModeEditorView`).

**Rule:** Views should only contain layout and binding code. All logic goes into coordinators, actions, or dedicated types. Views call methods on these types — they don't implement the logic themselves.

## 6. Use Swift Concurrency Consistently

**Problem:** The previous version mixed `DispatchQueue.main.asyncAfter` with `Task.sleep` and `@MainActor`, creating inconsistent threading patterns. It also used 7 instances of `Task.sleep` as workarounds for system API timing (window lifecycle, clipboard sync, focus activation).

**Rules:**
- In `@MainActor` or `@Observable` contexts, use `Task.sleep(for:)` instead of `DispatchQueue.main.asyncAfter`
- Use `Task.sleep(for: .milliseconds(N))` syntax, not nanosecond-based `Task.sleep(nanoseconds:)`
- When `Task.sleep` is used as a workaround for a system API (clipboard, focus, window), add a comment explaining *why* the delay is necessary and what it's waiting for
- Prefer polling with timeout over fixed delays when waiting for system state changes (clipboard changeCount, window availability, focus confirmation)

**Carve-out — blocking syscalls do NOT belong on the cooperative pool.** The "prefer Task over DispatchQueue" guidance above is about *timers and structured async*. It does **not** apply to *blocking synchronous* system calls (CoreML `MLModel(contentsOf:)`, `AVAudioEngine` input-node init, `AVAudioSession.setActive`, `engine.start()`). `Task.detached` schedules onto Swift's cooperative thread pool, which the runtime assumes tasks only *suspend* on; a call that blocks for seconds holds one of its scarce threads and starves the main actor. Bridge such calls to a GCD global queue via `withBlockingTask` / `withThrowingBlockingTask` (`Shared/Concurrency/BlockingWork.swift`). Do not "simplify" `withBlockingTask` back to `Task.detached` — that reintroduces the App Shell freeze. See [ADR-0003](../adr/0003-blocking-work-off-the-cooperative-pool.md).

## 7. No Force Unwraps in Production Code

**Problem:** The previous version had force unwraps (`as!`, `!`) in production code paths, risking runtime crashes.

**Rule:** Always use safe unwrapping (`guard let`, `if let`, `as?`). The only acceptable force unwrap is for static constants that are guaranteed valid at compile time (e.g., `URL(string: "https://example.com")!`).

## 8. Protocol-Oriented Abstractions

**What works well:** The previous version's protocol-based design for providers, actions, and destinations was its strongest architectural pattern. This version continues it.

**Rule:** Every major subsystem should have a protocol abstraction:
- `TranscriptionProvider` for speech-to-text backends
- `PostTranscriptionAction` for what happens after transcription
- Any new subsystem (e.g., history, LLM providers) must define a protocol before any concrete implementation

## 9. Proper Resource Cleanup

**Problem:** The previous version had potential memory leaks from timers without `deinit` cleanup and event monitors only cleaned up in `onDisappear`.

**Rule:**
- Any `Timer` must be invalidated in `deinit` or use `Task` with cancellation instead
- Any event monitor (`NSEvent.addLocalMonitorForEvents`, `NSEvent.addGlobalMonitorForEvents`) must have a corresponding removal
- Audio resources (files, sessions) must be cleaned up after use

## 10. Keep Files Focused

**Problem:** The previous version had 7 files over 300 lines, with `SettingsView.swift` at 812 lines containing 7 nested view structs.

**Rule:**
- One primary type per file
- If a view needs helper views, extract them to separate files when they exceed ~50 lines
- Settings tabs should be separate files if the settings UI grows

## 11. Responsiveness First

**Problem:** Cold-launch device traces showed the App Shell frozen for tens of seconds while heavy work (CoreML model specialization, audio engine warm-up) ran "in the background" but still starved the foreground. Perceived responsiveness, not raw throughput, is what the user feels.

**Rule:** Perceived responsiveness is the overriding priority. The visible shell renders before any backend dependency initializes, and every heavy or blocking operation runs off the foreground so the UI never stalls. Readiness is surfaced asynchronously via state changes, never by blocking the user behind a spinner.

This is a tenet, not a single mechanism — its concrete applications are recorded as ADRs:
- [ADR-0002](../adr/0002-shell-first-initialization.md) — defer heavy *initialization* past the first frame (shell-first).
- [ADR-0003](../adr/0003-blocking-work-off-the-cooperative-pool.md) — keep *blocking syscalls* off the cooperative thread pool (see the Rule 6 carve-out).

When you add code that does heavy or blocking work, the burden is on you to show it cannot stall the foreground.
