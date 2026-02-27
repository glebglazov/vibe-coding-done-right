# Copy Latest Capture Hotkey — Implementation Plan

## Overview

Add a new global hotkey ("Copy Latest Capture") that copies the most recent capture's **processed result** to the clipboard. This requires storing the processed text in history records, since currently only the raw transcription is persisted.

## Current State Analysis

- `TranscriptionRecord` stores `text` (raw transcription from Parakeet) but **not** the processed text that was actually sent to the output action.
- The processed text — after terminator, system prompt, captured selection, and optional bash script processing — is computed in the pipeline and discarded after `action.execute(text: processedText)`.
- Both `RecordingCoordinator` (line 263) and `PushToTypeCoordinator` (line 126) create records with only `text`.
- The hotkey system is well-patterned: each hotkey needs a `HotkeyBinding` in `AppSettings`, a `GlobalHotkeyManager`, a setup method, and wiring in `AppDependencies`.

### Key Discoveries:
- `TranscriptionRecord.actionResult` exists but is always passed as `nil` — unused vestige from a previous architecture.
- `RecordingIndicatorPanel.showCancelled()` provides a pattern for one-shot visual feedback (ephemeral panel with auto-hide).
- `TranscriptionHistory.latestRecord` returns the most recent record (`records.first`).

## Desired End State

A configurable global hotkey that, when pressed:
1. Copies the latest capture's processed text to the clipboard
2. Shows a brief visual indicator: clipboard icon → green checkmark → auto-hide
3. Shows an error indicator ("No captures yet") if history is empty

### Verification:
1. Record a capture with a mode that has bash processing — press the hotkey — clipboard should contain the bash script's output (not the raw transcription)
2. Record a capture with no processing (plain paste) — press the hotkey — clipboard should contain the pre-processed text (with terminator/selection applied)
3. Clear history — press the hotkey — should show "No captures yet" error indicator
4. The hotkey should be configurable in Settings > Home > Shortcuts

## What We're NOT Doing

- Not changing the existing copy buttons in the history UI (they still copy `fullCapture` / `actionResult`)
- Not adding visual feedback to the menu bar "copy" button (it already has its own "Copied!" label)
- Not storing additional metadata like which mode/destination was used

## Implementation Approach

Store `processedText` in `TranscriptionRecord`, then create a small handler class that reads the latest record and copies the processed text on hotkey press.

## Phase 1: Store Processed Text in History

### Overview
Add a `processedText` field to `TranscriptionRecord` and populate it in both coordinators.

### Changes Required:

#### 1. TranscriptionRecord
**File**: `vcdr/History/TranscriptionRecord.swift`
**Changes**: Add optional `processedText` field (optional for backward compat with existing JSON on disk)

```swift
struct TranscriptionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let processedText: String?  // Final text after all transforms, sent to the output action
    let modelName: String
    let recordingDuration: TimeInterval
    let timestamp: Date
    let actionResult: String?
    let capturedSelection: String?

    init(
        text: String,
        processedText: String? = nil,
        modelName: String,
        recordingDuration: TimeInterval,
        actionResult: String? = nil,
        capturedSelection: String? = nil,
        timestamp: Date = .now
    ) {
        self.id = UUID()
        self.text = text
        self.processedText = processedText
        self.modelName = modelName
        self.recordingDuration = recordingDuration
        self.actionResult = actionResult
        self.capturedSelection = capturedSelection
        self.timestamp = timestamp
    }

    // fullCapture and formattedDuration unchanged
}
```

#### 2. RecordingCoordinator — pass processedText
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`
**Changes**: At line 263, add `processedText: processedText` to the `TranscriptionRecord` init call.

```swift
let record = TranscriptionRecord(
    text: text,
    processedText: processedText,
    modelName: transcriptionProvider.name,
    recordingDuration: durationSeconds,
    actionResult: nil,
    capturedSelection: selection
)
```

#### 3. PushToTypeCoordinator — pass processedText
**File**: `vcdr/Orchestration/PushToTypeCoordinator.swift`
**Changes**: At line 126, add `processedText: processedText` to the `TranscriptionRecord` init call.

```swift
let record = TranscriptionRecord(
    text: text,
    processedText: processedText,
    modelName: "Push-to-Type",
    recordingDuration: 0,
    actionResult: nil,
    capturedSelection: selection
)
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Record a capture, check history JSON at `~/Library/Application Support/VCDR/history.json` — the record should contain a `processedText` field
- [ ] Existing history records (without `processedText`) still load correctly

---

## Phase 2: Add Hotkey Setting and Visual Feedback

### Overview
Add the `copyLatestCaptureHotkey` setting to `AppSettings`, add a "copied" indicator method to `RecordingIndicatorPanel`, and add the shortcut row to the settings UI.

### Changes Required:

#### 1. AppSettings — new hotkey binding
**File**: `vcdr/Core/Settings/AppSettings.swift`
**Changes**: Add `copyLatestCaptureHotkey` property, load/save logic, and UserDefaults key.

```swift
// In Keys enum:
static let copyLatestCaptureHotkey = "copyLatestCaptureHotkey"

// New property (after toggleRecordingHotkey):
var copyLatestCaptureHotkey: HotkeyBinding {
    didSet { save() }
}

// In init — load (after toggle recording load):
if let data = userDefaults.data(forKey: Keys.copyLatestCaptureHotkey),
   let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
    self.copyLatestCaptureHotkey = decoded
} else {
    self.copyLatestCaptureHotkey = .unassigned
}

// In save():
if let encoded = try? JSONEncoder().encode(copyLatestCaptureHotkey) {
    userDefaults.set(encoded, forKey: Keys.copyLatestCaptureHotkey)
}
```

#### 2. RecordingIndicatorPanel — add showCopied() method
**File**: `vcdr/UI/RecordingIndicator.swift`
**Changes**: Add a `showCopied()` method and a `CopiedIndicatorView` (following the `showCancelled()` / `CancelledIndicatorView` pattern). The view shows a clipboard icon that transitions to a green checkmark.

```swift
// On RecordingIndicatorPanel:
private static let copiedDisplayDuration: Duration = .seconds(1.5)
private static let copiedIconTransitionDelay: Duration = .milliseconds(300)

func showCopied() {
    hide()
    // Create ephemeral panel with CopiedIndicatorView
    // Same positioning logic as showCancelled()
    // Auto-hide after copiedDisplayDuration
}

// New view:
private struct CopiedIndicatorView: View {
    @State private var showCheckmark = false
    // Shows clipboard icon, then transitions to green checkmark after a brief delay
}
```

#### 3. RecordingIndicatorPanel — add showCopyError() method
**File**: `vcdr/UI/RecordingIndicator.swift`
**Changes**: Add a `showCopyError(_:)` method for the empty-history case. This reuses the error pattern (shows error icon + message pill, auto-hides).

```swift
private static let copyErrorDisplayDuration: Duration = .seconds(2)

func showCopyError(_ message: String) {
    hide()
    // Create ephemeral panel with error indicator + message
    // Same pattern as showCancelled() but with error styling
}
```

#### 4. HomeTabView — add shortcut row
**File**: `vcdr/UI/HomeTabView.swift`
**Changes**: Add a `ShortcutRecorderRow` for "Copy Latest Capture" in the Shortcuts section. This needs a reference to the handler's `updateHotkey()` method — we'll pass it through `AppDependencies`.

```swift
ShortcutRecorderRow(
    label: "Copy Latest Capture",
    keyCode: Binding(
        get: { dependencies.settings.copyLatestCaptureHotkey.keyCode },
        set: {
            dependencies.settings.copyLatestCaptureHotkey.keyCode = $0
            dependencies.copyLatestCaptureHandler.updateHotkey()
        }
    ),
    modifiers: Binding(
        get: { dependencies.settings.copyLatestCaptureHotkey.modifiers },
        set: {
            dependencies.settings.copyLatestCaptureHotkey.modifiers = $0
            dependencies.copyLatestCaptureHandler.updateHotkey()
        }
    )
)
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] New "Copy Latest Capture" shortcut row appears in Settings > Home > Shortcuts
- [ ] Assigning/clearing the shortcut persists across app restart

---

## Phase 3: Create CopyLatestCaptureHandler and Wire Everything

### Overview
Create the handler class, wire it in `AppDependencies`, and register its hotkey alongside the others.

### Changes Required:

#### 1. CopyLatestCaptureHandler
**File**: `vcdr/Orchestration/CopyLatestCaptureHandler.swift` (new file)
**Purpose**: Owns a `GlobalHotkeyManager`, reads latest capture from history, copies processed text to clipboard, shows visual feedback.

```swift
import AppKit
import OSLog

@MainActor
final class CopyLatestCaptureHandler {
    private let settings: AppSettings
    private let transcriptionHistory: TranscriptionHistory
    private let recordingIndicator: RecordingIndicatorPanel
    private let hotkeyManager = GlobalHotkeyManager()

    init(
        settings: AppSettings,
        transcriptionHistory: TranscriptionHistory,
        recordingIndicator: RecordingIndicatorPanel
    ) {
        self.settings = settings
        self.transcriptionHistory = transcriptionHistory
        self.recordingIndicator = recordingIndicator
    }

    func setupHotkey() {
        let binding = settings.copyLatestCaptureHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Copy latest capture hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            self?.copyLatestCapture()
        }
        hotkeyManager.onKeyUp = nil

        let keyCode = CGKeyCode(binding.keyCode)
        let modifiers = CGEventFlags(rawValue: binding.modifiers)
        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    private func copyLatestCapture() {
        guard let record = transcriptionHistory.latestRecord else {
            recordingIndicator.showCopyError("No captures yet")
            Logger.actions.info("Copy latest: no captures available")
            return
        }

        // Use processedText if available, fall back to fullCapture for old records
        let textToCopy = record.processedText ?? record.fullCapture
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)

        recordingIndicator.showCopied()
        Logger.actions.info("Copied latest capture to clipboard")
    }
}
```

#### 2. AppDependencies — create and expose handler
**File**: `vcdr/App/AppDependencies.swift`
**Changes**: Add `copyLatestCaptureHandler` property, create and wire it in `init()`, register its hotkey in `initialize()` and in the permission polling callback.

```swift
// New property:
let copyLatestCaptureHandler: CopyLatestCaptureHandler

// In init():
self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
    settings: settings,
    transcriptionHistory: history,
    recordingIndicator: recordingIndicator
)

// In initialize() — after accessibility check (alongside other setupHotkey calls):
copyLatestCaptureHandler.setupHotkey()

// In permission polling callback — alongside other setup calls:
self.copyLatestCaptureHandler.setupHotkey()
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Assign a hotkey for "Copy Latest Capture" in settings
- [ ] Record a capture with no processing → press hotkey → clipboard contains pre-processed text, visual indicator shows clipboard → green check
- [ ] Record a capture with bash processing → press hotkey → clipboard contains bash script output
- [ ] Clear history → press hotkey → shows "No captures yet" error indicator
- [ ] Old history records (without processedText) still work — hotkey copies fullCapture as fallback

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Testing Strategy

### Manual Testing Steps:
1. Fresh install: press copy hotkey → should show "No captures yet"
2. Record with default mode (no processing, paste) → press copy hotkey → clipboard has transcription with terminator
3. Record with bash processing mode → press copy hotkey → clipboard has bash script output
4. Record with push-to-type → press copy hotkey → clipboard has processed typed text
5. Assign/unassign/reassign the hotkey in settings → verify it works after each change
6. Press copy hotkey during active recording → should not interfere with recording indicator
7. Restart app → verify hotkey still works

## Performance Considerations

None significant — the operation is O(1) (read first element of array, copy string to clipboard).

## References

- Existing hotkey pattern: `RecordingCoordinator.setupHotkey()` at `vcdr/Orchestration/RecordingCoordinator.swift:61`
- One-shot indicator pattern: `RecordingIndicatorPanel.showCancelled()` at `vcdr/UI/RecordingIndicator.swift:102`
- History access: `TranscriptionHistory.latestRecord` at `vcdr/History/TranscriptionHistory.swift`
