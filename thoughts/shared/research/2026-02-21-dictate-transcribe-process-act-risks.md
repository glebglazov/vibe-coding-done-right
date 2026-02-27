---
date: 2026-02-21T18:00:00+00:00
researcher: Claude
git_commit: 7f97eab
branch: main
repository: vibe-coding-done-right
topic: "Risks, leaky abstractions, and fixes in the dictate-transcribe-process-act cycle"
tags: [research, codebase, architecture, abstractions, recording-coordinator, actions, transcription]
status: complete
last_updated: 2026-02-21
last_updated_by: Claude
---

# Research: Risks and Leaky Abstractions in the Dictate-Transcribe-Process-Act Cycle

**Date**: 2026-02-21T18:00:00+00:00
**Researcher**: Claude
**Git Commit**: 7f97eab
**Branch**: main
**Repository**: vibe-coding-done-right

## Research Question
What are the risks in the codebase regarding the dictate-transcribe-process-act cycle? Where are the leaky abstractions and how could they be fixed?

## Summary

The DTPA cycle flows through `RecordingCoordinator` as the central orchestrator: hotkey down starts recording (`AudioRecorder`), hotkey up stops it and triggers transcription (`ParakeetProvider`), text is transformed inline, and an action executes (`PasteAction`/`BashAction`). The protocols (`TranscriptionProvider`, `PostTranscriptionAction`) are clean, but the coordinator has accumulated action-type-specific branching, inline text transformation logic, and inconsistent dependency injection that leak implementation details upward. Below are the specific risks and leaky abstractions identified, roughly ordered by severity.

## Detailed Findings

### 1. RecordingCoordinator Has Action-Type-Specific Branching (Leaky Abstraction)

**Location**: `vcdr/Orchestration/RecordingCoordinator.swift:188-233`

The `PostTranscriptionAction` protocol abstracts the action (`execute(text:) -> String?`), but the coordinator bypasses this abstraction by branching on `mode.actionType` in three places:

```swift
// Line 193: System prompt only for bash
let finalText = (mode.actionType == .bash && mode.systemPromptEnabled && !mode.systemPrompt.isEmpty)
    ? mode.systemPrompt + "\n\n" + terminatedText
    : terminatedText

// Line 212: Focus restore only for paste
if settings.activeMode.actionType == .paste, let previousApp = previousActiveApp {
    previousApp.activate()
    try await Task.sleep(for: .milliseconds(100))
}

// Lines 222-233: Clipboard copy + optional re-paste only for bash
if mode.actionType == .bash, let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    // ... copies to clipboard, optionally creates a new PasteAction
}
```

**Risk**: Adding a third action type (e.g., an LLM action, HTTP webhook) requires modifying these three `if`/`switch` branches in the coordinator. The protocol abstraction promises extensibility but doesn't deliver it — the coordinator must know intimate details of each action type's pre- and post-execution needs.

**Potential fix**: Move pre-execution behavior (focus restore, system prompt prepend) and post-execution behavior (clipboard copy, re-paste) into the actions themselves, or define a richer protocol:

```swift
protocol PostTranscriptionAction: Sendable {
    var name: String { get }
    func prepare(context: ActionContext) async throws -> String  // transform text
    func execute(text: String) async throws -> String?
    func postExecute(output: String?, context: ActionContext) async throws
}
```

Alternatively, make the text transformation pipeline part of the `Mode` rather than the coordinator.

### 2. Text Transformation Pipeline Is Implicit and Inline

**Location**: `vcdr/Orchestration/RecordingCoordinator.swift:188-203`

Three text transformations happen sequentially inside `processTranscription()`:
1. Terminator application (line 189-191) — via `applyTerminator()`
2. System prompt prepend (line 193-195) — inline conditional
3. Selection append (line 198-203) — inline conditional

These are not composable or independently testable. They're interleaved with mode-type checks and coordinator state management.

**Risk**: Adding a new transformation (auto-capitalization, LLM rewriting, template substitution) means adding more inline code in the coordinator. The transformations can't be reordered, composed, or configured per-mode without growing this method.

**Potential fix**: Extract a `TextPipeline` or make `Mode` responsible for transforming text:

```swift
struct Mode {
    func transformTranscription(_ text: String, selection: String?) -> String {
        var result = text
        if terminatorTemplateEnabled { result = applyTerminator(result) }
        if actionType == .bash && systemPromptEnabled { result = systemPrompt + "\n\n" + result }
        if let selection { result += "\n\n" + selection }
        return result
    }
}
```

### 3. Inconsistent Dependency Injection in RecordingCoordinator

**Location**: `vcdr/Orchestration/RecordingCoordinator.swift:23-34`

The coordinator receives `ParakeetProvider`, `AppSettings`, and `MediaPlaybackController` via init injection, but creates four other dependencies internally:

```swift
// Injected (good)
private let settings: AppSettings
private let transcriptionProvider: ParakeetProvider
private let mediaPlaybackController: MediaPlaybackController

// Created internally (breaks DI pattern)
private let audioRecorder = AudioRecorder()            // line 24 equivalent
private let hotkeyManager = GlobalHotkeyManager()      // line 24 equivalent
private let recordingIndicator = RecordingIndicatorPanel()  // line 24
private let selectionCapturer = SelectionCapturer()    // line 26
```

**Risk**: `AudioRecorder`, `GlobalHotkeyManager`, `RecordingIndicatorPanel`, and `SelectionCapturer` cannot be mocked for testing. This violates CLAUDE.md rule #2 ("All dependencies must be injected... the only place where objects are created is `AppDependencies.swift`"). It also means `AppDependencies` can't control their lifecycle.

**Potential fix**: Inject all four through `init`, create them in `AppDependencies`. For `RecordingIndicatorPanel`, consider injecting a protocol if the UI coupling is undesirable.

### 4. AudioRecorder ↔ ParakeetProvider Format Coupling

**Location**: `vcdr/Audio/AudioRecorder.swift:40-47` and `vcdr/Transcription/ParakeetProvider.swift:71`

AudioRecorder hardcodes 16kHz mono PCM WAV:
```swift
AVSampleRateKey: 16000,
AVNumberOfChannelsKey: 1,
AVLinearPCMBitDepthKey: 16,
```

ParakeetProvider calls `asr.transcribe(audioFileURL, source: .system)` and trusts the file is in the right format. There's no type-level contract between them.

**Risk**: If a different transcription provider requires a different format (e.g., 44.1kHz, or Opus), the AudioRecorder settings need to change but nothing enforces this. The coupling is implicit — it works because there's only one provider, but breaks the `TranscriptionProvider` protocol's promise of substitutability.

**Potential fix**: Either have the `TranscriptionProvider` protocol declare its required audio format, or have `AudioRecorder` accept format configuration:

```swift
protocol TranscriptionProvider: Sendable {
    var requiredAudioFormat: AudioFormat { get }
    // ...
}
```

### 5. File Lifecycle Management Leaks Into Coordinator

**Location**: `vcdr/Orchestration/RecordingCoordinator.swift:177`

```swift
try? FileManager.default.removeItem(at: audioURL)
```

The coordinator is responsible for deleting the temp audio file after transcription. The `AudioRecorder` creates the file, the `ParakeetProvider` reads it, and the coordinator deletes it. File lifecycle is spread across three types with no ownership semantics.

**Risk**: If transcription throws before the delete, the file leaks. If two cycles run concurrently (theoretically prevented by state machine, but not enforced at the type level), you get race conditions on file access. The `try?` silently swallows delete failures.

**Potential fix**: Have `AudioRecorder.stopRecording()` return a wrapper type that auto-deletes on deinit or have the transcription provider handle cleanup:

```swift
struct RecordingResult {
    let url: URL
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}
```

### 6. BashAction Blocks a Cooperative Thread

**Location**: `vcdr/Actions/BashAction.swift:30-32`

```swift
try process.run()
process.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
```

`waitUntilExit()` is a synchronous blocking call. Since `execute()` is `async`, this blocks a Swift concurrency cooperative thread pool thread. If a bash command hangs or takes a long time, it degrades the entire thread pool.

**Risk**: A long-running or hung script blocks the cooperative thread pool. There's no timeout mechanism — a broken script hangs the app indefinitely with no way to cancel.

**Potential fix**: Use `Process.terminationHandler` with a continuation, and add a configurable timeout:

```swift
func execute(text: String) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // ... resume continuation
        }
        try process.run()
    }
}
```

### 7. State Machine Transitions Are Not Enforced

**Location**: `vcdr/Orchestration/RecordingCoordinator.swift:7-13, 80-166`

The state enum is simple:
```swift
enum State: Equatable {
    case idle, recording, transcribing, executing, error(String)
}
```

Transitions are enforced by `guard` checks scattered across methods:
- `onHotkeyDown`: guards `state == .idle`
- `stopRecordingAndTranscribe`: guards `state == .recording`
- Various methods set state directly

**Risk**: There's no compile-time guarantee that invalid transitions can't happen. A future refactor could accidentally set `state = .recording` from `.executing`. The guards are defensive but not structural. In practice, the current code is correct, but it's fragile to change.

**Potential fix**: A `mutating func transition(to:)` method that validates transitions, or use an event-driven approach where the state machine declares valid transitions.

### 8. Selection Capture Side Effects

**Location**: `vcdr/Orchestration/SelectionCapturer.swift:16-45`

`SelectionCapturer.capture()` simulates Cmd+C before recording starts, temporarily hijacking the clipboard:

```swift
simulateCmdC()
try? await Task.sleep(for: Self.clipboardSettleDelay)  // 100ms hope-based delay
```

**Risk**:
- Modifies clipboard state (saves/restores, but there's a race window)
- Can trigger clipboard managers (Paste, Maccy, etc.) that react to clipboard changes
- 100ms delay is a best-effort guess — slow apps may not process Cmd+C in time
- Apps that don't support Cmd+C (terminals, custom editors) silently fail
- The `try?` swallows the sleep cancellation, masking bugs

### 9. RecordingCoordinator Directly Creates PasteAction in Bash Flow

**Location**: `vcdr/Orchestration/RecordingCoordinator.swift:230`

```swift
let pasteAction = PasteAction()
try await pasteAction.execute(text: trimmedOutput)
```

Inside the bash action's post-execution flow, the coordinator creates a *second* action (PasteAction) to paste the script output. This bypasses `makeAction()`, hardcodes a concrete type, and means the bash flow has a hidden dependency on PasteAction.

**Risk**: This is a composition of two actions that's handled ad-hoc. If PasteAction's behavior changes (e.g., needs configuration), this second instantiation is easy to miss.

### 10. TranscriptionProvider Protocol Uses Concrete Type in Coordinator

**Location**: `vcdr/Orchestration/RecordingCoordinator.swift:18`

```swift
private let transcriptionProvider: ParakeetProvider
```

Despite having a `TranscriptionProvider` protocol, the coordinator holds the concrete `ParakeetProvider` type. This defeats the protocol abstraction — you can't swap in a different provider without changing the coordinator.

**Potential fix**: Change the type to `any TranscriptionProvider` (or a generic):
```swift
private let transcriptionProvider: any TranscriptionProvider
```

## Architecture Documentation

### Current DTPA Cycle Flow

```
[Hotkey Down] → onHotkeyDown()
    ├── Check state == .idle
    ├── Check transcriptionProvider.isReady
    ├── Capture previous app reference
    ├── SelectionCapturer.capture() [simulates Cmd+C]
    ├── AudioRecorder.startRecording()
    └── state = .recording

[Hotkey Up] → stopRecordingAndTranscribe() [synchronous!]
    ├── MediaPlaybackController.resumeIfNeeded()
    ├── Check state == .recording
    ├── AudioRecorder.stopRecording() → URL?
    ├── state = .transcribing
    └── Task { processTranscription(audioURL:) }

processTranscription():
    ├── transcriptionProvider.transcribe(audioFileURL:) → String
    ├── FileManager.removeItem(audioURL)
    ├── Text pipeline (inline):
    │   ├── Apply terminator template
    │   ├── Prepend system prompt (bash only)
    │   └── Append captured selection
    ├── state = .executing
    ├── makeAction() → PostTranscriptionAction
    ├── Pre-action (paste only): activate previous app
    ├── action.execute(text:)
    ├── Post-action (bash only): copy to clipboard, optional re-paste
    └── state = .idle
```

### Abstraction Boundaries (Current)

| Boundary | Protocol | Leak |
|----------|----------|------|
| Transcription | `TranscriptionProvider` | Coordinator holds concrete `ParakeetProvider`; audio format not specified |
| Action | `PostTranscriptionAction` | Coordinator branches on action type for pre/post behavior |
| Audio | None (concrete `AudioRecorder`) | Not injected, format hardcoded |
| Hotkey | None (concrete `GlobalHotkeyManager`) | Not injected |
| Text transform | None | Inline in coordinator |

## Code References

- `vcdr/Orchestration/RecordingCoordinator.swift:170-247` — Main processTranscription method with all leaks
- `vcdr/Orchestration/RecordingCoordinator.swift:249-257` — makeAction factory
- `vcdr/Orchestration/RecordingCoordinator.swift:23-34` — Mixed DI pattern
- `vcdr/Actions/BashAction.swift:28-47` — Blocking waitUntilExit
- `vcdr/Actions/PostTranscriptionAction.swift:17-21` — Protocol that doesn't capture pre/post lifecycle
- `vcdr/Transcription/TranscriptionProvider.swift:20-25` — Protocol missing audio format contract
- `vcdr/Orchestration/SelectionCapturer.swift:16-45` — Clipboard side effects
- `vcdr/Audio/AudioRecorder.swift:40-47` — Hardcoded audio format
- `vcdr/Core/Settings/Mode.swift:1-63` — Mode struct with all action-specific fields

## Severity Summary

| # | Issue | Severity | Effort to Fix |
|---|-------|----------|--------------|
| 1 | Action-type branching in coordinator | High | Medium — richer protocol or action-owned pre/post |
| 2 | Inline text pipeline | Medium | Low — extract to Mode or pipeline type |
| 3 | Inconsistent DI | Medium | Low — mechanical refactor |
| 4 | Audio format coupling | Medium | Low — add format to protocol |
| 5 | File lifecycle spread | Low | Low — wrapper type |
| 6 | BashAction thread blocking | Medium | Medium — async Process wrapper |
| 7 | Unenforced state transitions | Low | Low — transition method |
| 8 | Selection capture side effects | Low | Hard — fundamental approach limitation |
| 9 | Ad-hoc PasteAction in bash flow | Medium | Low — part of fix #1 |
| 10 | Concrete type for provider | Low | Trivial — change to `any TranscriptionProvider` |
