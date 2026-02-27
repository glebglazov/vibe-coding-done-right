# Append Highlighted Text Implementation Plan

## Overview

Always attempt to capture the user's currently selected (highlighted) text when the PTT hotkey is pressed. If text was selected, append it to the transcription output separated by a double newline. If nothing was selected, the transcription is unchanged.

## Current State Analysis

- `RecordingCoordinator.onHotkeyDown()` captures `previousActiveApp` at line 99 — the user's app is still focused at this point, which is exactly when we need to simulate Cmd+C
- Clipboard write pattern exists in `PasteAction.swift:18-20` (clear + setString)
- CGEvent keyboard simulation exists in `PasteAction.swift:27-32` (Cmd+V)
- Virtual key code 8 = C key (from `GlobalHotkeyManager.swift:133`)
- No clipboard read operations exist anywhere in the codebase yet
- No Cmd+C simulation exists yet

### Key Discoveries:
- `NSPasteboard.general.changeCount` increments on every clipboard change — we can use this to detect if Cmd+C actually copied something
- The clipboard settle delay pattern (50ms in PasteAction, 100ms for focus restoration) is established
- `RecordingCoordinator` is at 275 lines — we need to keep additions minimal or extract to a helper to stay under 300

## Desired End State

When the user presses the PTT hotkey:
1. VCDR saves the current clipboard state (changeCount + string content)
2. VCDR simulates Cmd+C to copy whatever is selected
3. After a settle delay, checks if the clipboard changeCount changed
4. If changed, reads the new clipboard string as "captured selection"
5. Restores the previous clipboard string
6. Proceeds with normal recording → transcription flow
7. After transcription and text transforms, appends `\n\n` + captured selection

**Verification**: Highlight text in TextEdit, press PTT, say something, release. The pasted/executed text should be `<transcription>\n\n<highlighted text>`. Without highlighting, only the transcription appears. Original clipboard is preserved.

## What We're NOT Doing

- No per-mode setting toggle — always active
- No configurable separator or template
- No Accessibility API approach (`kAXSelectedTextAttribute`) — Cmd+C is more universal
- No rich text / image clipboard preservation — only string content is saved/restored
- No prepend option — always appends after transcription

## Implementation Approach

Create a focused `SelectionCapturer` struct to encapsulate the Cmd+C simulation and clipboard change detection. Integrate it into `RecordingCoordinator.onHotkeyDown()` (capture) and `processTranscription()` (append). This keeps the coordinator under 300 lines while isolating the clipboard manipulation concern.

## Phase 1: Create SelectionCapturer

### Overview
Create a small, focused struct that simulates Cmd+C, detects clipboard changes, and restores the previous clipboard state.

### Changes Required:

#### 1. New file: `vcdr/Orchestration/SelectionCapturer.swift`
**Changes**: New file — a `Sendable` struct with a single `capture() async -> String?` method.

```swift
import AppKit
import OSLog

struct SelectionCapturer: Sendable {
    // MARK: - Constants

    /// Delay after simulating Cmd+C for the target app to update the clipboard
    private static let clipboardSettleDelay: Duration = .milliseconds(100)

    /// Virtual key code for the C key
    private static let cKeyCode: UInt16 = 8

    /// Attempts to capture the currently selected text in the frontmost app
    /// by simulating Cmd+C. Returns the selected text, or nil if nothing was selected.
    /// Restores the original clipboard string after capture.
    func capture() async -> String? {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousString = pasteboard.string(forType: .string)

        simulateCmdC()

        // Wait for the target app to process Cmd+C and update the clipboard
        try? await Task.sleep(for: Self.clipboardSettleDelay)

        guard pasteboard.changeCount != previousChangeCount else {
            // Clipboard didn't change — nothing was selected
            return nil
        }

        let capturedText = pasteboard.string(forType: .string)

        // Restore previous clipboard contents so the user's clipboard isn't affected
        pasteboard.clearContents()
        if let previousString {
            pasteboard.setString(previousString, forType: .string)
        }

        guard let capturedText, !capturedText.isEmpty else {
            return nil
        }

        Logger.actions.info("Captured highlighted text (\(capturedText.count) chars)")
        return capturedText
    }

    private func simulateCmdC() {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.cKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [x] N/A — this phase is just the utility; integration is in Phase 2

---

## Phase 2: Integrate into RecordingCoordinator

### Overview
Wire SelectionCapturer into the recording flow: capture on hotkey down, append after transcription.

### Changes Required:

#### 1. `vcdr/Orchestration/RecordingCoordinator.swift`
**Changes**: Add two properties, capture selection in `onHotkeyDown`, append in `processTranscription`.

**Add properties** (after line 24, alongside `recordingIndicator`):
```swift
private let selectionCapturer = SelectionCapturer()
private var capturedSelection: String?
```

**In `onHotkeyDown`** — after `previousActiveApp` capture (line 99) and before `startRecording` (line 102), add:
```swift
// Capture any highlighted text in the frontmost app before recording starts
capturedSelection = await selectionCapturer.capture()
```

**In `processTranscription`** — after constructing `finalText` (line 176) and before `state = .executing` (line 178), add:
```swift
// Append captured selection text if the user had text highlighted
let textWithSelection: String
if let selection = capturedSelection {
    textWithSelection = finalText + "\n\n" + selection
    capturedSelection = nil
} else {
    textWithSelection = finalText
    capturedSelection = nil
}
```

Then replace `finalText` with `textWithSelection` in:
- `action.execute(text:)` call at line 190

**Clear capturedSelection at error paths**: In the `guard !text.isEmpty` block (line 163) and in the `catch` block (line 209), add `capturedSelection = nil` to prevent stale data.

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- [x] RecordingCoordinator.swift stays under 300 lines (291 lines)

#### Manual Verification:
- [ ] Highlight text in TextEdit → press PTT → say something → release → output contains transcription + `\n\n` + highlighted text
- [ ] Don't highlight anything → press PTT → say something → release → output contains only transcription
- [ ] After VCDR finishes, Cmd+V pastes what was in clipboard before (clipboard restored)
- [ ] Works with both paste and bash action modes
- [ ] Works when highlight capture finds nothing (empty selection in an app)
- [ ] Quick key release (race condition path) still works correctly

---

## Testing Strategy

### Manual Testing Steps:
1. Open TextEdit, type "Hello World", select "World"
2. Press PTT, say "this is a test", release
3. Verify output is: `this is a test\n\nWorld` (or with terminator applied)
4. Repeat without selecting anything — verify only transcription appears
5. Copy something to clipboard, then use VCDR without selecting — verify clipboard unchanged
6. Test with bash action mode — verify `$VCDR_TEXT` env var contains the appended text
7. Test quick key release — verify no crash or stale selection

## Performance Considerations

- The 100ms clipboard settle delay adds latency before recording starts. This is acceptable since the user is holding the key and won't notice the slight delay before the recording indicator appears.
- If the delay proves too long, it can be reduced to 50ms (matching PasteAction's settle delay), though 100ms is safer for slower apps.

## References

- CGEvent Cmd+V pattern: `vcdr/Actions/PasteAction.swift:27-32`
- Clipboard write pattern: `vcdr/Actions/PasteAction.swift:18-20`
- Virtual key codes: `vcdr/Hotkeys/GlobalHotkeyManager.swift:129-137`
- Recording flow entry point: `vcdr/Orchestration/RecordingCoordinator.swift:79-125`
- Text transformation chain: `vcdr/Orchestration/RecordingCoordinator.swift:169-176`
