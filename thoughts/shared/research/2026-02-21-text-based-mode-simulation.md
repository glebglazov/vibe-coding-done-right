---
date: 2026-02-21T22:29:12+00:00
researcher: Claude
git_commit: 7f97eab
branch: main
repository: vibe-coding-done-right
topic: "Text-based simulation mode for testing modes without dictation"
tags: [research, codebase, testing, simulation, modes, transcription, actions]
status: complete
last_updated: 2026-02-21
last_updated_by: Claude
---

# Research: Text-Based Simulation Mode for Testing Modes Without Dictation

**Date**: 2026-02-21T22:29:12+00:00
**Researcher**: Claude
**Git Commit**: 7f97eab
**Branch**: main
**Repository**: vibe-coding-done-right

## Research Question

Is a text-based simulation mode for testing modes without dictation worthwhile? How could it be arranged architecturally?

## Summary

The idea is solid and worth pursuing. The current architecture has a tight coupling between the hotkey→record→transcribe→execute pipeline that makes it impossible to test the text transformation + action execution stages without actually speaking into a microphone. A text-based simulation would let you type text and run it through the exact same pipeline that real dictation uses — testing terminators, system prompts, selection appending, paste actions, and bash actions — without requiring audio input or a loaded Parakeet model.

The architecture already has the right seams for this. The key insight is that `RecordingCoordinator.processTranscription()` does everything after transcription in a linear pipeline: apply terminator → prepend system prompt → append selection → execute action. A simulation mode just needs to inject text at the entry point of that pipeline, skipping only the audio recording and Parakeet transcription steps.

## Is It Worth It?

**Yes**, for several concrete reasons:

### 1. Current testing pain
Today, testing a mode requires: holding a hotkey, speaking clearly, waiting for Parakeet to transcribe, observing the result. Each iteration takes 3-5 seconds minimum. For bash actions with complex templates, you often need to test with specific text patterns (e.g., text with existing punctuation to test terminator edge cases, or multi-line text for system prompts). Speaking specific test strings accurately is error-prone and slow.

### 2. What it would let you test without speaking
- **Terminator templates**: Does `<dot><space>` append correctly? What about when text already ends with `?` or `!`? (The `applyTerminator` logic at `RecordingCoordinator.swift:267-288` has special handling for trailing punctuation.)
- **System prompts**: Is the system prompt prepended correctly? Does the newline formatting look right?
- **Selection appending**: Does `\n\n` + selection get appended correctly?
- **Bash action templates**: Does `{}` / `$VCDR_TEXT` substitution work? What does the script output look like for various inputs?
- **Paste action timing**: Does the text actually paste correctly?
- **Mode switching**: After switching modes, does the new mode's settings apply correctly to the next execution?

### 3. What it would NOT help test
- Audio recording quality and microphone selection
- Parakeet transcription accuracy
- Hotkey registration and event tap behavior
- The race condition handling between keyDown/keyUp
- MediaPlaybackController pause/resume behavior

### 4. Cost is low
The implementation is straightforward given the existing architecture. No major refactoring needed — it's mostly about providing an alternative entry point that skips the audio/transcription steps.

## How the Pipeline Works Today

```
onHotkeyDown()
  ├── await transcriptionProvider.isReady         ← SKIP in simulation
  ├── previousActiveApp capture                   ← KEEP (for paste focus restore)
  ├── await selectionCapturer.capture()           ← KEEP or MOCK
  ├── await audioRecorder.startRecording()        ← SKIP in simulation
  └── state = .recording                          ← SKIP in simulation

stopRecordingAndTranscribe()
  ├── audioRecorder.stopRecording() → URL         ← SKIP in simulation
  ├── state = .transcribing                       ← SKIP in simulation
  └── Task { processTranscription(audioURL:) }    ← REPLACE entry point

processTranscription(audioURL:)
  ├── transcriptionProvider.transcribe() → String ← REPLACE with user-typed text
  ├── FileManager.removeItem(audioURL)            ← SKIP
  ├── applyTerminator(text)                       ← KEEP
  ├── prepend systemPrompt (bash only)            ← KEEP
  ├── append capturedSelection                    ← KEEP
  ├── state = .executing                          ← KEEP
  ├── makeAction()                                ← KEEP
  ├── previousApp.activate() (paste only)         ← KEEP
  ├── action.execute(text)                        ← KEEP
  ├── bash output handling                        ← KEEP
  └── state = .idle                               ← KEEP
```

**The natural seam** is between the transcription step and the text transformation pipeline. Everything from `applyTerminator` onward is what you want to test, and it all operates on a `String` — it doesn't care where that string came from.

## Architectural Approaches

### Approach A: Extract a `processText(_ text: String)` Method (Simplest)

Extract the post-transcription pipeline from `processTranscription(audioURL:)` into a new method that accepts text directly:

```swift
// RecordingCoordinator.swift

/// Run text through the active mode's full pipeline (transform + action)
/// without recording or transcribing. Used for text-based simulation.
func simulateWithText(_ text: String) async {
    guard state == .idle else { return }
    previousActiveApp = NSWorkspace.shared.frontmostApplication
    // Optionally capture selection if needed
    // capturedSelection = await selectionCapturer.capture()
    await processText(text)
}

/// Extracted from processTranscription — everything after transcription
private func processText(_ rawText: String) async {
    // ... applyTerminator, systemPrompt, selection, makeAction, execute
}
```

Then `processTranscription(audioURL:)` becomes:
```swift
let text = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
try? FileManager.default.removeItem(at: audioURL)
guard !text.isEmpty else { ... }
await processText(text)
```

**Pros**: Minimal change. No new types. No architectural disruption.
**Cons**: Adds a public method to `RecordingCoordinator` that's only used for simulation. Coordinator grows slightly.

### Approach B: UI-Only Simulation Tab/Section in Settings

Add a small "Test Mode" section in the settings UI (either in the Home tab or as a separate section in Mode detail):

```
┌─────────────────────────────────────┐
│ Test Mode                           │
│                                     │
│ [Text field: type test input here ] │
│                                     │
│ [▶ Run]  [⊞ Include Selection]     │
│                                     │
│ Result: "Hello world."              │
│ Action: Paste                       │
│ Output: (pasted to clipboard)       │
└─────────────────────────────────────┘
```

This would call `coordinator.simulateWithText(inputText)` with the text from the field.

**Pros**: Discoverable, visual, great UX for iterating on mode settings.
**Cons**: Adds UI complexity. Needs to decide where it lives (mode detail? home tab? separate tab?).

### Approach C: Dry-Run Mode (Transform Only, No Execute)

A variant where the simulation shows you what the pipeline *would* produce without actually executing the action:

```swift
func dryRun(_ text: String) -> String {
    let mode = settings.activeMode
    var result = text
    if mode.terminatorTemplateEnabled {
        result = Self.applyTerminator(result, terminator: mode.terminatorTemplate)
    }
    if mode.actionType == .bash && mode.systemPromptEnabled && !mode.systemPrompt.isEmpty {
        result = mode.systemPrompt + "\n\n" + result
    }
    // selection appending could be simulated with a parameter
    return result
}
```

**Pros**: Zero side effects. Safe. Fast. Pure function.
**Cons**: Doesn't test the actual action execution (paste/bash), which is often what you want to verify. Two modes of simulation might be confusing.

### Recommended: Approach A + B Combined

1. **Extract `processText(_:)`** from `processTranscription` (Approach A) — this is a clean refactor that improves separation of concerns regardless of simulation
2. **Add a simulation UI** in the Mode detail view (Approach B) — this gives you a text field and a "Run" button that calls `simulateWithText(_:)` through the coordinator
3. **Optionally add dry-run preview** (Approach C) — show the transformed text before execution, as a preview below the text field

This gives you both the quick "does my terminator work?" dry-run preview AND the full "does my bash script handle this input correctly?" live execution test.

## Existing Architectural Seams

The codebase already has the right patterns to support this:

1. **`processTranscription` already takes text as an intermediate value** (`RecordingCoordinator.swift:173`) — the audio URL is consumed early and the rest operates on `String`
2. **`applyTerminator` is already a static method** (`RecordingCoordinator.swift:267`) — can be called independently
3. **`makeAction()` already abstracts action creation** (`RecordingCoordinator.swift:249-257`) — returns `any PostTranscriptionAction`
4. **Actions are stateless** — `PasteAction()` and `BashAction(commandTemplate:)` are created fresh each time, no setup needed
5. **`toggleRecording()` already provides a non-hotkey entry point** (`RecordingCoordinator.swift:68-77`) — proves the coordinator supports alternative triggers

## What Would NOT Change

- The hotkey → record → transcribe flow stays exactly the same
- No new protocols needed
- No dependency injection changes
- No changes to `AppDependencies`
- Actions themselves don't change
- Settings/Mode model doesn't change

## Implementation Complexity

| Component | Effort |
|-----------|--------|
| Extract `processText(_:)` from `processTranscription` | Small — move ~60 lines into a new method |
| Add `simulateWithText(_:)` public method | Trivial — 5-10 lines |
| Add UI text field + run button in mode detail | Small — ~40 lines of SwiftUI |
| Dry-run preview (optional) | Small — ~15 lines, pure function |
| **Total** | **~120 lines of new code, minimal risk** |

## Code References

- `vcdr/Orchestration/RecordingCoordinator.swift:170-247` — processTranscription (the method to split)
- `vcdr/Orchestration/RecordingCoordinator.swift:267-288` — applyTerminator (already static, easily testable)
- `vcdr/Orchestration/RecordingCoordinator.swift:249-257` — makeAction factory
- `vcdr/Orchestration/RecordingCoordinator.swift:68-77` — toggleRecording (existing non-hotkey entry point)
- `vcdr/Actions/PostTranscriptionAction.swift:17-21` — Action protocol
- `vcdr/Actions/PasteAction.swift:13-36` — Paste action execute
- `vcdr/Actions/BashAction.swift:8-48` — Bash action execute
- `vcdr/Core/Settings/Mode.swift:3-63` — Mode struct with all settings

## Historical Context (from thoughts/)

- `thoughts/shared/research/2026-02-21-dictate-transcribe-process-act-risks.md` — Identified that the text transformation pipeline is inline and not independently testable (finding #2). A simulation mode directly addresses this by enabling pipeline testing without audio.
- `thoughts/shared/research/2026-02-20-vcdr-architecture-and-swift-fundamentals.md` — Mentions `MockTranscriptionProvider` as a testability pattern. A text simulation is essentially an even simpler version of this — bypassing transcription entirely rather than mocking it.
- `thoughts/shared/plans/2026-02-21-bash-action-system-prompt.md` — Includes manual testing steps that require speaking specific text. A simulation mode would make these tests much faster.

## Open Questions

- Should the simulation text field live in the Mode detail view, the Home tab, or be a separate panel?
- Should simulation capture the current selection (via Cmd+C) like real recording does, or should selection be provided as a separate text field?
- Should dry-run preview happen live as you type, or only when you click "Run"?
- Should simulation results (for bash actions) be shown in the UI or just executed normally?
