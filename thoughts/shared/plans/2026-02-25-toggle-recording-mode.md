# Toggle Recording Mode (Start/Stop) with Push-to-Talk Upgrade

## Overview

Add a "toggle recording" mode that allows the user to start recording with a single press and stop with another press, as an alternative to holding the push-to-talk shortcut. The toggle mode is entered by **upgrading** from push-to-talk: while holding the push-to-talk shortcut, the user presses an additional modifier key (any modifier not already in the shortcut). This "upgrades" the hold-to-record session into a toggle session — the user can release all keys and recording continues. To stop, they tap the push-to-talk shortcut again.

A visual indicator (red glowing border around the recording circle) distinguishes toggle mode from normal push-to-talk.

## Current State Analysis

- `GlobalHotkeyManager` registers a CGEvent tap that listens for `.keyDown` and `.keyUp` only — no `.flagsChanged` support
- `RecordingCoordinator` uses a synchronous `onKeyUp` callback to stop recording with minimal latency
- `RecordingIndicatorView` shows a 44pt circle with `.ultraThinMaterial` fill, a red waveform animation during recording, and `.shadow(radius: 2)` — no concept of recording "mode"
- `IndicatorPhaseState` has `phase`, `rejectCount`, and `errorMessage` — no toggle mode flag

### Key Discoveries:
- `onKeyUp` is called **synchronously** from the CGEvent tap (no GCD dispatch) — `RecordingCoordinator.swift:70-71`
- `onKeyDown` is dispatched **asynchronously** via `DispatchQueue.main.async` — `GlobalHotkeyManager.swift:92`
- Race condition check at `RecordingCoordinator.swift:149` catches early key release during `startRecording()` await — must be toggle-mode-aware
- `GlobalHotkeyManager.isHotkeyActive` tracks whether the key is currently held — `GlobalHotkeyManager.swift:12`

## Desired End State

1. While holding push-to-talk (e.g. Control+/), pressing an additional modifier (e.g. Option) upgrades the recording to toggle mode
2. The recording indicator shows a red glowing border when in toggle mode
3. Releasing all keys in toggle mode does NOT stop recording
4. Tapping the push-to-talk shortcut again stops recording and proceeds to transcription
5. All existing push-to-talk behavior is unchanged when no upgrade occurs

### Verification:
- Hold Control+/ → recording starts, normal appearance → release → recording stops (existing behavior preserved)
- Hold Control+/, press Option while holding → border turns red/glowing → release all keys → recording continues → tap Control+/ → recording stops and transcribes
- Visual indicator clearly distinguishes push-to-talk from toggle mode

## What We're NOT Doing

- No separate hotkey binding for toggle mode (only upgrade from push-to-talk)
- No settings UI for configuring the upgrade modifier
- No pulsing/animated glow (static red border + glow for simplicity — can add later)
- No toggle mode for push-to-type (only applies to push-to-talk voice recording)

## Implementation Approach

The upgrade is detected via `.flagsChanged` CGEvent events. When any new modifier is added to the existing key combination while `isHotkeyActive` is true, a new `onModifierUpgrade` callback fires. The coordinator uses three boolean flags to manage the toggle state: `isToggleRecordingMode`, `ignoreNextKeyUp`, and `skipNextKeyDown`. The visual change is driven by a new `isToggleMode` property on `IndicatorPhaseState`.

## Phase 1: GlobalHotkeyManager — flagsChanged Detection

### Overview
Add `.flagsChanged` event detection so the manager can notify the coordinator when the user adds a modifier key while the hotkey is being held.

### Changes Required:

#### 1. Add upgrade callback and event mask
**File**: `vcdr/Hotkeys/GlobalHotkeyManager.swift`

Add a new callback property alongside the existing ones (after line 19):

```swift
/// Called synchronously from the CGEvent tap when a new modifier key is pressed
/// while the hotkey is already held (e.g. user presses Option while holding Control+/).
/// Used to "upgrade" push-to-talk to toggle recording mode.
var onModifierUpgrade: (() -> Void)?
```

Update the event mask in `register()` to include `.flagsChanged` (replace line 33):

```swift
let eventMask = (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)
```

#### 2. Handle flagsChanged in handleEvent
**File**: `vcdr/Hotkeys/GlobalHotkeyManager.swift`

Add a new branch in `handleEvent` (after the keyUp block, before the final return at line 110):

```swift
} else if type == .flagsChanged && isHotkeyActive {
    let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    // Detect any new modifier beyond the original shortcut's modifiers.
    // This fires when e.g. Option is added to a Control+/ shortcut.
    let newModifiers = flags.subtracting(targetModifiers)
    if !newModifiers.isEmpty {
        Logger.hotkeys.debug("[tap] modifier upgrade detected while hotkey active")
        onModifierUpgrade?()
    }
    // Pass through — don't swallow modifier changes
    return Unmanaged.passUnretained(event)
}
```

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Existing push-to-talk (hold and release) still works identically
- [ ] Adding a print/log in onModifierUpgrade shows it fires when Option is added during a hold

---

## Phase 2: RecordingCoordinator — Toggle Recording Logic

### Overview
Add three state flags to manage toggle recording mode. Modify the start/stop flow so that after an upgrade, keyUp is ignored and the next keyDown+keyUp stops recording.

### Changes Required:

#### 1. Add toggle state flags
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add three new properties after line 28 (`recordingStartInstant`):

```swift
/// Whether the current recording session is in toggle mode (start/stop, not hold-to-record)
private var isToggleRecordingMode = false
/// Set after upgrading to toggle mode — causes the next keyUp to be ignored
/// (the user is releasing keys after upgrading, not intending to stop)
private var ignoreNextKeyUp = false
/// Set after a toggle-mode stop — prevents the stale async keyDown from buzzing
private var skipNextKeyDown = false
```

#### 2. Wire onModifierUpgrade in setupHotkey
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add the upgrade callback in `setupHotkey()`, after the `onKeyUp` assignment (after line 72):

```swift
hotkeyManager.onModifierUpgrade = { [weak self] in
    self?.upgradeToToggleRecording()
}
```

#### 3. Add upgradeToToggleRecording method
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add a new method (after `setupHotkey`/`updateHotkey`, around line 79):

```swift
/// Called synchronously from the CGEvent tap when the user adds a modifier
/// while holding the push-to-talk shortcut. Upgrades the current hold-to-record
/// session to toggle mode so the user can release keys and keep recording.
private func upgradeToToggleRecording() {
    guard state == .recording else { return }
    guard !isToggleRecordingMode else { return }
    isToggleRecordingMode = true
    ignoreNextKeyUp = true
    recordingIndicator.setToggleMode(true)
    Logger.app.info("Push-to-talk upgraded to toggle recording mode")
}
```

#### 4. Modify onHotkeyDown to handle toggle mode
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add two early returns at the top of `onHotkeyDown()`, after the debug log on line 96 and before the error recovery on line 98:

```swift
// Skip stale async keyDown dispatched before a toggle-mode keyUp stop.
// The synchronous keyUp handler already stopped recording — this keyDown
// was queued by GCD before that and is now irrelevant.
if skipNextKeyDown {
    skipNextKeyDown = false
    return
}

// In toggle mode, a keyDown during recording is a no-op. The synchronous
// keyUp handler that follows this keyDown will handle the actual stop.
if state == .recording && isToggleRecordingMode {
    return
}
```

#### 5. Modify stopRecordingAndTranscribe for toggle mode
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add an early return at the very top of `stopRecordingAndTranscribe()`, before the existing state guard (before line 171):

```swift
// Toggle mode: ignore the keyUp right after upgrading.
// The user just added a modifier to upgrade and is now releasing keys.
if ignoreNextKeyUp {
    ignoreNextKeyUp = false
    Logger.app.debug("[stopRecordingAndTranscribe] ignoring keyUp after toggle upgrade")
    return
}
```

And in the existing stop logic, after `recordingStartInstant = nil` (line 183) and before the `audioRecorder.stopRecording()` call, add toggle cleanup:

```swift
// If stopping from toggle mode, set flag to skip the stale async keyDown
// that was dispatched before this synchronous stop ran.
if isToggleRecordingMode {
    isToggleRecordingMode = false
    skipNextKeyDown = true
    recordingIndicator.setToggleMode(false)
}
```

#### 6. Fix race condition check for toggle mode
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Modify the race condition check at line 149 to account for toggle mode:

```swift
if fromHotkey && !hotkeyManager.isHotkeyActive && !isToggleRecordingMode {
```

#### 7. Reset toggle flags on recording start
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

In `onHotkeyDown()`, right after `state = .recording` (line 140), reset the toggle flags to ensure clean state:

```swift
state = .recording
isToggleRecordingMode = false
ignoreNextKeyUp = false
skipNextKeyDown = false
```

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] **Normal push-to-talk preserved:** Hold Control+/ → recording starts → release → recording stops → transcription runs
- [ ] **Upgrade to toggle:** Hold Control+/ → recording starts → press Option (while still holding) → release all keys → recording continues
- [ ] **Stop toggle recording:** After upgrading, tap Control+/ → recording stops → transcription runs
- [ ] **No buzz on toggle stop:** Stopping a toggle recording does not trigger the shake animation
- [ ] **Quick release during startRecording:** If keys are released very quickly before startRecording completes, recording still stops (race condition handling still works)

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 3: RecordingIndicator — Red Glowing Border

### Overview
Add a visual distinction for toggle recording mode: a red border and red glow shadow around the recording circle.

### Changes Required:

#### 1. Add isToggleMode to IndicatorPhaseState
**File**: `vcdr/UI/RecordingIndicator.swift`

Add a new property to `IndicatorPhaseState` (after line 21, `errorMessage`):

```swift
var isToggleMode: Bool = false
```

#### 2. Add setToggleMode to RecordingIndicatorPanel
**File**: `vcdr/UI/RecordingIndicator.swift`

Add a new method to `RecordingIndicatorPanel` (after the `buzz()` method, around line 86):

```swift
func setToggleMode(_ enabled: Bool) {
    phaseState.isToggleMode = enabled
}
```

Also reset toggle mode in the `show()` method, alongside the existing resets (after line 42):

```swift
phaseState.isToggleMode = false
```

#### 3. Add toggle mode visuals to RecordingIndicatorView
**File**: `vcdr/UI/RecordingIndicator.swift`

Add constants for the toggle mode visuals (after line 105, `phaseTransitionDuration`):

```swift
private static let toggleBorderWidth: CGFloat = 2.5
private static let toggleGlowRadius: CGFloat = 8
private static let toggleGlowOpacity: Double = 0.5
```

Modify the circle in the ZStack (replace lines 119-122) to include the toggle mode border and glow:

```swift
Circle()
    .fill(.ultraThinMaterial)
    .frame(width: Self.circleSize, height: Self.circleSize)
    .overlay(
        Circle()
            .stroke(Color.red, lineWidth: Self.toggleBorderWidth)
            .opacity(phaseState.isToggleMode ? 1 : 0)
    )
    .shadow(
        color: phaseState.isToggleMode ? .red.opacity(Self.toggleGlowOpacity) : .clear,
        radius: phaseState.isToggleMode ? Self.toggleGlowRadius : 0
    )
    .shadow(radius: 2)
```

Add animation for the toggle mode transition (after the existing `.animation` on line 168):

```swift
.animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.isToggleMode)
```

### Success Criteria:

#### Automated Verification:
- [x] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] **Normal push-to-talk:** Recording circle has no red border — looks identical to current behavior
- [ ] **Toggle mode upgrade:** When upgrading, red border and glow appear with a smooth transition
- [ ] **Toggle mode stop:** When stopping toggle recording, red border disappears before transitioning to processing spinner
- [ ] **Glow visibility:** Red glow is visible against both light and dark menu bar backgrounds
- [ ] **Border doesn't clip:** The border fits within the panel bounds and doesn't get cut off

---

## Testing Strategy

### Manual Testing Steps:
1. **Basic push-to-talk** — Hold shortcut, speak, release → transcription works as before
2. **Upgrade flow** — Hold shortcut, add Option, release all → recording continues with red indicator
3. **Stop toggle** — After upgrade, tap shortcut → recording stops, transcription runs
4. **Quick upgrade** — Hold shortcut, quickly add Option and release → recording continues (no race condition)
5. **Cancel during startRecording** — Upgrade during the brief startRecording await → recording starts in toggle mode
6. **Multiple sessions** — Do several push-to-talk recordings, then an upgrade, then more push-to-talk → all behave correctly, no stale state

## Edge Cases

- **Auto-repeat keyDown during toggle mode:** The GlobalHotkeyManager already filters auto-repeat events (line 88). No change needed.
- **User adds multiple modifiers:** `flags.subtracting(targetModifiers)` catches any new modifier, not just Option. First modifier addition triggers the upgrade; subsequent additions are no-ops (guard in `upgradeToToggleRecording`).
- **Push-to-type during toggle recording:** `PushToTypeCoordinator` uses its own separate `GlobalHotkeyManager`. It would try to show the text overlay, but since `RecordingCoordinator` state is `.recording`, there could be a conflict with the shared `RecordingIndicatorPanel`. However, the push-to-type overlay is a separate panel (`PushToTypePanel`), so there's no visual conflict. The indicator panel would continue showing the toggle recording state.

## References

- `GlobalHotkeyManager.swift:74-111` — Current event handling logic
- `RecordingCoordinator.swift:50-75` — Hotkey setup and callbacks
- `RecordingCoordinator.swift:95-163` — Recording start logic with race condition handling
- `RecordingCoordinator.swift:169-207` — Synchronous recording stop logic
- `RecordingIndicator.swift:100-171` — SwiftUI recording indicator view
