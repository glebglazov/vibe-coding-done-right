# Paste Script Output to Current App — Implementation Plan

## Overview

Add a "Paste output of script to current app" checkbox to the Custom Script action settings. When enabled, the stdout from the script is captured and pasted into the previously-active app via the same clipboard + Cmd+V mechanism used by `PasteAction`. Primary use case: running a Claude Code instance as the script that processes voice input and returns a response to paste.

## Current State Analysis

- `BashAction` already captures stdout (`BashAction.swift:32-33`) but discards it on success
- `PostTranscriptionAction.execute(text:)` returns `Void` — no way to pass output back
- Focus restoration only happens for `.paste` action type (`RecordingCoordinator.swift:184-188`)
- `PasteAction` handles clipboard write + Cmd+V simulation (`PasteAction.swift:18-32`)

## Desired End State

A new Toggle in `ModeDetailView` under the Custom Script section: "Paste output to current app". When enabled:
1. Script runs with `$VCDR_TEXT` as before
2. Script's stdout is captured
3. Focus is restored to the app that was active before recording
4. Stdout is pasted into that app via clipboard + Cmd+V

Verification: Create a mode with action type "Custom script", command `echo "hello from script"`, enable "Paste output to current app", run the mode, and see "hello from script" pasted into the previously-active app.

## What We're NOT Doing

- No new action type — this is a modifier on the existing bash action
- No changes to how `$VCDR_TEXT` or system prompt work
- No stderr handling for paste (only stdout)
- No UI to show the script output before pasting

## Implementation Approach

Modify the `PostTranscriptionAction` protocol to return `String?` from `execute`. BashAction returns stdout, PasteAction returns nil. The coordinator checks the new `pasteScriptOutput` flag on the mode and, if set, uses the captured output to restore focus and paste.

---

## Phase 1: Add `pasteScriptOutput` Setting to Mode

### Overview
Add the boolean flag to `Mode` with backward-compatible Codable decoding.

### Changes Required:

#### 1. Mode struct
**File**: `vcdr/Core/Settings/Mode.swift`

Add property after `systemPrompt`:
```swift
var pasteScriptOutput: Bool
```

Update `makeDefault()` — add `pasteScriptOutput: false` (implicitly via default parameter).

Update `init` — add parameter with default:
```swift
pasteScriptOutput: Bool = false
```

Update `init(from decoder:)` — add backward-compatible decode:
```swift
pasteScriptOutput = try container.decodeIfPresent(Bool.self, forKey: .pasteScriptOutput) ?? false
```

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

---

## Phase 2: Change Protocol and Action Return Types

### Overview
Modify `PostTranscriptionAction.execute` to return `String?` so actions can pass output back to the coordinator.

### Changes Required:

#### 1. PostTranscriptionAction protocol
**File**: `vcdr/Actions/PostTranscriptionAction.swift`

Change:
```swift
func execute(text: String) async throws
```
To:
```swift
@discardableResult
func execute(text: String) async throws -> String?
```

#### 2. PasteAction
**File**: `vcdr/Actions/PasteAction.swift`

Change `execute` signature to return `String?`, return `nil` at the end:
```swift
func execute(text: String) async throws -> String? {
    // ... existing logic unchanged ...
    Logger.actions.info("Paste simulated via Cmd+V")
    return nil
}
```

#### 3. BashAction
**File**: `vcdr/Actions/BashAction.swift`

Change `execute` signature to return `String?`, return stdout on success:
```swift
func execute(text: String) async throws -> String? {
    // ... existing logic ...
    if process.terminationStatus == 0 {
        Logger.actions.info("Command succeeded")
        return output  // Return stdout for potential paste
    } else {
        // ... existing error handling ...
    }
}
```

The `catch` blocks also need to satisfy the return type but they all throw, so no return needed there.

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

---

## Phase 3: Update Coordinator to Paste Script Output

### Overview
After the bash action executes, if `pasteScriptOutput` is enabled, restore focus and paste the captured stdout.

### Changes Required:

#### 1. RecordingCoordinator
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

In `processTranscription`, after `action.execute(text: finalText)` (line 190), add logic to handle the script output:

```swift
let output = try await action.execute(text: finalText)

// If "paste script output" is enabled, paste the captured stdout into the current app.
// No focus restoration needed — bash actions run in the background, so the user's app
// never loses focus.
if mode.actionType == .bash && mode.pasteScriptOutput,
   let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    let pasteAction = PasteAction()
    try await pasteAction.execute(text: output.trimmingCharacters(in: .whitespacesAndNewlines))
}
```

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

---

## Phase 4: Add UI Toggle

### Overview
Add the "Paste output to current app" checkbox in the Custom Script section of ModeDetailView.

### Changes Required:

#### 1. ModeDetailView
**File**: `vcdr/UI/ModesTabView.swift`

In the `if mode.actionType == .bash` block (line 114), after the system prompt section (line 127), add:

```swift
Toggle("Paste output to current app", isOn: $mode.pasteScriptOutput)
    .help("Paste the script's stdout into the previously-active app after execution")
```

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] New toggle appears in Mode detail view when "Custom script" action is selected
- [ ] Toggle state persists after closing and reopening settings
- [ ] With `echo "test output"` as command and toggle ON: output is pasted into the previous app
- [ ] With toggle OFF: script runs but nothing is pasted (existing behavior)
- [ ] With a script that outputs nothing: no paste happens, no error
- [ ] Existing paste action still works unchanged
- [ ] Existing bash action without the toggle still works unchanged

## References

- `PostTranscriptionAction.swift:17` — protocol definition
- `BashAction.swift:32-33` — existing stdout capture
- `PasteAction.swift:18-32` — clipboard + Cmd+V logic
- `RecordingCoordinator.swift:184-188` — focus restoration logic
- `Mode.swift:10-11` — systemPromptEnabled pattern to follow
- `ModesTabView.swift:119` — existing toggle pattern
