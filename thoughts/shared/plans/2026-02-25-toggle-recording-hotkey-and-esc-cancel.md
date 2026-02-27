# Toggle Recording Hotkey + Esc Cancel Implementation Plan

## Overview

Add a separate "Toggle Recording" global hotkey (configurable, press-to-start / press-to-stop) and a hardcoded Esc key to cancel any active recording (discarding audio without transcribing).

## Current State Analysis

- Push-to-Talk uses `GlobalHotkeyManager` with key-down/key-up semantics (`RecordingCoordinator.setupHotkey()`)
- `toggleRecording()` exists on `RecordingCoordinator` (line 82) but only accessible from the UI button
- No cancel recording functionality — stopping always transcribes
- `GlobalHotkeyManager` always consumes matching events (no conditional pass-through)
- Three coordinators each own a `GlobalHotkeyManager` instance: `RecordingCoordinator`, `ModeSwitcherCoordinator`, `PushToTypeCoordinator`

### Key Code References:
- `RecordingCoordinator` at 325 lines (already over the 300-line limit from CLAUDE.md)
- `GlobalHotkeyManager.handleEvent` returns `nil` to consume or `Unmanaged.passUnretained(event)` to pass through (lines 74–111)
- `AppSettings` stores hotkeys as `HotkeyBinding` structs with JSON persistence (lines 39–47)
- `AppDependencies.initialize()` calls `coordinator.setupHotkey()` when accessibility is granted (lines 89–93, 121–124)
- `RecordingIndicatorPanel.show()` currently takes no parameters (line 40)

## Desired End State

1. A "Toggle Recording" shortcut appears in Settings above "Push-to-Talk", configurable via `ShortcutRecorderRow`
2. Pressing the Toggle Recording hotkey starts recording; pressing again stops and transcribes
3. Pressing Esc during any active recording (from PTT or Toggle) cancels the recording, discards audio, and briefly shows a grey cross on the floating indicator
4. Esc passes through normally when not recording (so it works in other apps)
5. When recording via Toggle Recording (or UI button), the floating indicator shows a small red border to distinguish from PTT mode

### Verification:
- Toggle Recording hotkey starts/stops recording correctly
- Esc cancels during recording and shows grey cross briefly
- Esc passes through when not recording
- PTT still works as before (hold-to-record)
- All shortcuts appear in Settings UI

## What We're NOT Doing

- Making Esc configurable (it's hardcoded)
- Changing Push-to-Talk behavior
- Adding Esc cancel during transcribing/executing states (only during recording)

## Implementation Approach

Single phase — all changes are small and interdependent. The approach adds an `isEnabled` flag to `GlobalHotkeyManager` for conditional event consumption, a `cancelRecording()` method to `RecordingCoordinator`, and wires everything up.

**300-line concern:** `RecordingCoordinator` is already at 325 lines. The additions (~50 lines) will push it to ~375. To mitigate: keep the new methods minimal and trim verbose debug logging (e.g., lines 96, 111, 136, 138, 150, 170) in the same change to reclaim ~30 lines.

## Phase 1: Toggle Recording Hotkey + Esc Cancel

### Overview
Add toggle recording hotkey, Esc cancel, and the corresponding UI.

### Changes Required:

#### 1. Add `isEnabled` to GlobalHotkeyManager
**File**: `vcdr/Hotkeys/GlobalHotkeyManager.swift`
**Changes**: Add `var isEnabled: Bool = true` property. When `isEnabled` is false, `handleEvent` passes all events through without consuming them.

```swift
var isEnabled: Bool = true
```

In `handleEvent`, after matching keyCode and modifiers for keyDown (line 85):
```swift
if type == .keyDown {
    guard keyCode == targetKeyCode && flags == targetModifiers else {
        return Unmanaged.passUnretained(event)
    }
    guard isEnabled else {
        return Unmanaged.passUnretained(event)
    }
    // ... existing consume logic
}
```

Same for keyUp — check `isEnabled` before consuming (line 95):
```swift
} else if type == .keyUp {
    guard keyCode == targetKeyCode && isHotkeyActive else {
        return Unmanaged.passUnretained(event)
    }
    guard isEnabled else {
        isHotkeyActive = false
        return Unmanaged.passUnretained(event)
    }
    // ... existing consume logic
}
```

Note: On keyUp when disabled, we still reset `isHotkeyActive = false` so the state stays consistent — the key physically went up regardless of whether we consume the event.

#### 2. Add `toggleRecordingHotkey` to AppSettings
**File**: `vcdr/Core/Settings/AppSettings.swift`
**Changes**: Add new `HotkeyBinding` property with persistence.

Add property alongside existing hotkeys (after `pushToTypeHotkey`, line 47):
```swift
var toggleRecordingHotkey: HotkeyBinding {
    didSet { save() }
}
```

Add UserDefaults key (in `Keys` enum, after line 70):
```swift
static let toggleRecordingHotkey = "toggleRecordingHotkey"
```

Add loading in `init()` (after push-to-type loading, after line 116):
```swift
// Load toggle recording hotkey (default: unassigned)
if let data = userDefaults.data(forKey: Keys.toggleRecordingHotkey),
   let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
    self.toggleRecordingHotkey = decoded
} else {
    self.toggleRecordingHotkey = .unassigned
}
```

Add saving in `save()` (after pushToTypeHotkey encoding, after line 168):
```swift
if let encoded = try? JSONEncoder().encode(toggleRecordingHotkey) {
    userDefaults.set(encoded, forKey: Keys.toggleRecordingHotkey)
}
```

#### 3. Add toggle recording + Esc cancel to RecordingCoordinator
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`
**Changes**: Add two new `GlobalHotkeyManager` instances, `setupToggleRecordingHotkey()`, `setupEscCancel()`, `cancelRecording()`, and Esc enable/disable toggling.

Add properties (after existing properties, around line 28):
```swift
private let toggleRecordingHotkeyManager = GlobalHotkeyManager()
private let escCancelManager = GlobalHotkeyManager()
private var isToggleMode = false
```

Add Esc keyCode constant (in the Constants section, around line 283):
```swift
private static let escapeKeyCode: CGKeyCode = 53
private static let cancelledIndicatorDisplayDuration: Duration = .seconds(1)
```

In existing `setupHotkey()`, in the `onKeyDown` closure (line 62), add before `onHotkeyDown`:
```swift
hotkeyManager.onKeyDown = { [weak self] in
    Task { @MainActor in
        self?.isToggleMode = false
        await self?.onHotkeyDown(fromHotkey: true)
    }
}
```

In existing `toggleRecording()` (line 82), set `isToggleMode = true` before the Task:
```swift
func toggleRecording() {
    switch state {
    case .idle, .error:
        isToggleMode = true
        Task { await onHotkeyDown() }
    case .recording:
        stopRecordingAndTranscribe()
    default:
        break
    }
}
```

Add `setupToggleRecordingHotkey()`:
```swift
func setupToggleRecordingHotkey() {
    guard settings.toggleRecordingHotkey.isAssigned else {
        toggleRecordingHotkeyManager.unregister()
        return
    }

    toggleRecordingHotkeyManager.onKeyDown = { [weak self] in
        Task { @MainActor in
            self?.toggleRecording()
        }
    }
    toggleRecordingHotkeyManager.onKeyUp = nil

    let keyCode = CGKeyCode(settings.toggleRecordingHotkey.keyCode)
    let modifiers = CGEventFlags(rawValue: settings.toggleRecordingHotkey.modifiers)
    _ = toggleRecordingHotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
}

func updateToggleRecordingHotkey() {
    setupToggleRecordingHotkey()
}
```

Add `setupEscCancel()`:
```swift
func setupEscCancel() {
    escCancelManager.isEnabled = false  // only active during recording
    escCancelManager.onKeyDown = { [weak self] in
        Task { @MainActor in
            self?.cancelRecording()
        }
    }
    escCancelManager.onKeyUp = nil
    _ = escCancelManager.register(keyCode: Self.escapeKeyCode, modifiers: [])
}
```

Add `cancelRecording()`:
```swift
func cancelRecording() {
    guard state == .recording else { return }
    escCancelManager.isEnabled = false
    mediaPlaybackController.resumeIfNeeded()

    if let audioURL = audioRecorder.stopRecording() {
        try? FileManager.default.removeItem(at: audioURL)
    }

    state = .idle
    Logger.app.info("Recording cancelled via Esc")

    // Show grey cross briefly, then hide
    recordingIndicator.showCancelled()
}
```

Toggle `escCancelManager.isEnabled` in existing methods:

In `onHotkeyDown()`, replace `recordingIndicator.show()` (line 142) with:
```swift
recordingIndicator.show(withBorder: isToggleMode)
escCancelManager.isEnabled = true
```

In `stopRecordingAndTranscribe()`, at the top after the state guard (around line 171):
```swift
escCancelManager.isEnabled = false
```

In `onHotkeyDown()` failure paths (lines 115 and 157), add:
```swift
escCancelManager.isEnabled = false
```

**Trimming debug logging to offset line growth:** Remove or condense the verbose `Logger.app.debug("[onHotkeyDown]...")` and `Logger.app.debug("[stopRecordingAndTranscribe]...")` calls at lines 96, 111, 136, 138, 150, 170 — these were useful for diagnosing the race condition (now fixed) but add ~12 lines of noise.

#### 4. Update RecordingIndicatorPanel
**File**: `vcdr/UI/RecordingIndicator.swift`
**Changes**:
- `show()` gains a `withBorder: Bool` parameter — when true, adds a red stroke around the circle (toggle mode)
- Add `showCancelled()` that swaps to a grey "xmark" and auto-hides after 1 second
- Add `CancelledIndicatorView` alongside `RecordingIndicatorView`
- Add `showBorder: Bool` to `IndicatorPhaseState`

Update `IndicatorPhaseState` (line 17):
```swift
@Observable
@MainActor
final class IndicatorPhaseState {
    var phase: IndicatorPhase = .recording
    var showBorder: Bool = false
    var rejectCount: Int = 0
    var errorMessage: String?
}
```

Update `show()` to accept a border flag (line 40):
```swift
func show(withBorder: Bool = false) {
    phaseState.phase = .recording
    phaseState.showBorder = withBorder
    phaseState.errorMessage = nil
    guard panel == nil else { return }

    // ... rest of existing show() logic unchanged
}
```

Update `RecordingIndicatorView` circle to support the red border (line 119):
```swift
Circle()
    .fill(.ultraThinMaterial)
    .frame(width: Self.circleSize, height: Self.circleSize)
    .overlay(
        Circle()
            .strokeBorder(.red, lineWidth: phaseState.showBorder ? 2 : 0)
    )
    .shadow(radius: 2)
```

Add `showCancelled()` to `RecordingIndicatorPanel` (after `hide()`, line 95):
```swift
private static let cancelledIndicatorDisplayDuration: Duration = .seconds(1)

func showCancelled() {
    hide()  // close the recording indicator if still open

    let hostingView = NSHostingView(rootView: CancelledIndicatorView())
    hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

    let panel = NSPanel(
        contentRect: hostingView.frame,
        styleMask: [.nonactivatingPanel, .borderless],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.contentView = hostingView
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true

    if let screen = NSScreen.main ?? NSScreen.screens.first {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.maxY - menuBarHeight - Self.panelHeight - Self.menuBarGap
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    panel.orderFrontRegardless()
    self.panel = panel

    Task { @MainActor in
        try? await Task.sleep(for: Self.cancelledIndicatorDisplayDuration)
        self.hide()
    }
}
```

Add `CancelledIndicatorView` (after `RecordingIndicatorView`):
```swift
private struct CancelledIndicatorView: View {
    private static let circleSize: CGFloat = 44
    private static let iconSize: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: Self.circleSize, height: Self.circleSize)
                .shadow(radius: 2)

            Image(systemName: "xmark")
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
```

#### 5. Wire up in AppDependencies
**File**: `vcdr/App/AppDependencies.swift`
**Changes**: Call `setupToggleRecordingHotkey()` and `setupEscCancel()` alongside existing hotkey setup.

In `initialize()` (after line 92, alongside existing hotkey setups):
```swift
coordinator.setupToggleRecordingHotkey()
coordinator.setupEscCancel()
```

In `startPermissionPolling()` (after line 124, alongside existing hotkey setups):
```swift
self.coordinator.setupToggleRecordingHotkey()
self.coordinator.setupEscCancel()
```

#### 6. Add Toggle Recording to Settings UI
**File**: `vcdr/UI/HomeTabView.swift`
**Changes**: Add `ShortcutRecorderRow` for Toggle Recording above Push-to-Talk in the Shortcuts section.

Insert before the existing Push-to-Talk row (before line 78):
```swift
ShortcutRecorderRow(
    label: "Toggle Recording",
    keyCode: Binding(
        get: { dependencies.settings.toggleRecordingHotkey.keyCode },
        set: {
            dependencies.settings.toggleRecordingHotkey.keyCode = $0
            dependencies.coordinator.updateToggleRecordingHotkey()
        }
    ),
    modifiers: Binding(
        get: { dependencies.settings.toggleRecordingHotkey.modifiers },
        set: {
            dependencies.settings.toggleRecordingHotkey.modifiers = $0
            dependencies.coordinator.updateToggleRecordingHotkey()
        }
    )
)
```

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Toggle Recording shortcut appears in Settings above Push-to-Talk
- [ ] Assigning and pressing Toggle Recording hotkey starts recording
- [ ] Pressing Toggle Recording hotkey again stops recording and transcribes
- [ ] Pressing Esc during recording (from either PTT or Toggle) cancels recording
- [ ] Grey cross appears briefly on the floating indicator after Esc cancel, then auto-hides
- [ ] Esc key works normally in other apps when not recording
- [ ] Push-to-Talk still works as before (hold-to-record, no border on indicator)
- [ ] Toggle Recording shows red border on the floating indicator; PTT does not
- [ ] Clearing the Toggle Recording shortcut works correctly
- [ ] All shortcuts survive app restart (persisted correctly)

## References

- `vcdr/Orchestration/RecordingCoordinator.swift` — recording state machine (325 lines)
- `vcdr/Hotkeys/GlobalHotkeyManager.swift` — CGEvent tap for global hotkeys (160 lines)
- `vcdr/Core/Settings/AppSettings.swift` — hotkey binding storage (179 lines)
- `vcdr/UI/RecordingIndicator.swift` — floating panel for recording/cancelled states (195 lines)
- `vcdr/UI/HomeTabView.swift` — shortcuts UI section (148 lines)
- `vcdr/App/AppDependencies.swift` — hotkey setup wiring (139 lines)
