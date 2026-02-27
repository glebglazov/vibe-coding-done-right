# Toggle Recording: Double-Tap & Long Press Upgrade

## Overview

Replace the modifier-based toggle upgrade (which leaks key characters into the active app) with two deterministic triggers:

1. **Double-tap**: Tap the push-to-talk shortcut twice quickly (< 400ms between presses) to start toggle recording
2. **Long press**: Hold the push-to-talk shortcut for > 2 seconds to auto-upgrade to toggle recording

Both converge on the same toggle recording state: red glowing border on the indicator, release keys without stopping, tap shortcut again to stop.

## Current State Analysis

The modifier-based upgrade from the previous plan is already implemented:
- `GlobalHotkeyManager` listens for `.flagsChanged` events and has `onModifierUpgrade` callback
- `RecordingCoordinator` has toggle state flags (`isToggleRecordingMode`, `ignoreNextKeyUp`, `skipNextKeyDown`) and `upgradeToToggleRecording()` method
- `RecordingIndicatorView` has red border + glow visuals for toggle mode

**Problem**: When adding a modifier (e.g., Option) while holding the push-to-talk shortcut (e.g., Control+/), macOS re-sends keyDown events with the new modifier set. The CGEvent tap's modifier check doesn't match, so the event passes through and "/" gets typed into the active app.

### Key Discoveries:
- `onKeyUp` is called **synchronously** from the CGEvent tap — `GlobalHotkeyManager.swift:112`
- `onKeyDown` is dispatched **asynchronously** via `DispatchQueue.main.async` — `GlobalHotkeyManager.swift:98`
- A new `onDoubleTap` callback can also be called **synchronously** from the tap, ensuring it runs before any scheduled delayed stop Task
- The delayed stop Task (scheduled on MainActor) cannot execute until the CGEvent tap callback returns and the run loop processes the MainActor queue — this guarantees cancellation ordering

## Desired End State

1. Normal push-to-talk works as before (hold to record, release to transcribe) with ~400ms of imperceptible extra recording time
2. Double-tapping the shortcut (two quick taps < 400ms apart) starts toggle recording with the red glowing border
3. Holding the shortcut for 2+ seconds auto-upgrades to toggle recording with the red glowing border
4. Tapping the shortcut stops toggle recording (immediate, no delay)
5. No key character leaks into the active app
6. Settings UI below the Push-to-Talk shortcut: enable/disable double-tap, enable/disable long press, configurable long press duration
7. When double-tap is disabled, no delayed stop (zero latency on push-to-talk release)
8. When long press is disabled, no auto-upgrade timer

### Verification:
- Hold Control+/ → recording starts → release → recording stops after ~400ms delay → transcription runs
- Tap Control+/ twice quickly → recording starts in toggle mode (red border) → release → recording continues → tap Control+/ → stops
- Hold Control+/ for 2+ seconds → red border appears (auto-upgrade) → release → recording continues → tap Control+/ → stops
- No "/" characters typed into the active app during any flow

## What We're NOT Doing

- No separate hotkey binding for toggle mode
- No modifier-based upgrade (removing this)
- No configurable double-tap window (fixed at 400ms — not user-facing)

## Implementation Approach

**Double-tap** is detected by `GlobalHotkeyManager` tracking `lastKeyDownTime`. When two keyDown events arrive within 400ms, it fires a synchronous `onDoubleTap` callback instead of the async `onKeyDown`.

**Delayed stop** in `RecordingCoordinator`: on keyUp during non-toggle recording, a 400ms delayed stop is scheduled (via Task.sleep). If a double-tap arrives during this window, the stop is cancelled and toggle mode is activated. Recording continues seamlessly during the delay.

**Long press** uses a 2-second Task.sleep timer started when recording begins. If the user is still holding when it fires, toggle mode activates. Cancelled on keyUp.

## Phase 1: GlobalHotkeyManager — Double-Tap Detection

### Overview
Remove `.flagsChanged` handling and `onModifierUpgrade`. Add `lastKeyDownTime` tracking and `onDoubleTap` callback. On double-tap, call `onDoubleTap` synchronously instead of dispatching `onKeyDown` async.

### Changes Required:

#### 1. Replace modifier callback with double-tap callback
**File**: `vcdr/Hotkeys/GlobalHotkeyManager.swift`

Remove `onModifierUpgrade` (lines 20-23). Add double-tap state and callback:

```swift
/// Called synchronously from the CGEvent tap when a double-tap is detected
/// (two keyDown events within the double-tap window). Used to upgrade
/// push-to-talk to toggle recording mode.
var onDoubleTap: (() -> Void)?

private var lastKeyDownTime: ContinuousClock.Instant?
private static let doubleTapWindow: Duration = .milliseconds(400)
```

#### 2. Revert event mask to keyDown + keyUp only
**File**: `vcdr/Hotkeys/GlobalHotkeyManager.swift`

Remove `.flagsChanged` from the event mask (line 37-39):

```swift
let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
```

#### 3. Replace flagsChanged handler with double-tap detection in keyDown
**File**: `vcdr/Hotkeys/GlobalHotkeyManager.swift`

Remove the `} else if type == .flagsChanged && isHotkeyActive {` block (lines 114-125).

In the keyDown handler, replace the simple dispatch (lines 94-99) with double-tap detection:

```swift
let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
if !isRepeat {
    let now = ContinuousClock.Instant.now
    let isDoubleTap: Bool
    if let last = lastKeyDownTime, now - last < Self.doubleTapWindow {
        isDoubleTap = true
        lastKeyDownTime = nil
    } else {
        isDoubleTap = false
        lastKeyDownTime = now
    }

    isHotkeyActive = true
    if isDoubleTap {
        Logger.hotkeys.debug("[tap] double-tap detected, calling onDoubleTap synchronously")
        onDoubleTap?()
    } else {
        Logger.hotkeys.debug("[tap] keyDown fired, isHotkeyActive=true")
        DispatchQueue.main.async { self.onKeyDown?() }
    }
}
return nil
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Existing push-to-talk (hold and release) still works
- [ ] No "/" characters leak into the active app
- [ ] Double-tap is detected (verify via log output)

---

## Phase 2: RecordingCoordinator — Delayed Stop, Double-Tap Handler, Long Press Timer

### Overview
Replace the modifier-based upgrade with: (1) delayed stop on keyUp to allow double-tap detection, (2) double-tap handler that cancels the delayed stop and upgrades, (3) long press timer that auto-upgrades after 2 seconds.

### Changes Required:

#### 1. Add new state and constants
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Add new properties after the existing toggle flags (after line 36):

```swift
/// Pending delayed stop task — allows double-tap detection by deferring the
/// actual recording stop for a brief window after keyUp.
private var pendingStopTask: Task<Void, Never>?
/// Long press timer — auto-upgrades to toggle mode if the user holds
/// the shortcut beyond the threshold.
private var longPressTask: Task<Void, Never>?
```

Add new constants in the `// MARK: - Constants` section:

```swift
/// Window after keyUp before actually stopping recording.
/// Matches the double-tap window so a second tap can cancel the stop.
private static let doubleTapStopDelay: Duration = .milliseconds(400)
/// Hold duration before auto-upgrading to toggle recording mode.
private static let longPressThreshold: Duration = .seconds(2)
```

#### 2. Replace modifier upgrade wiring with double-tap in setupHotkey
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Replace `hotkeyManager.onModifierUpgrade` (line 81-83) with:

```swift
hotkeyManager.onDoubleTap = { [weak self] in
    self?.handleDoubleTap()
}
```

#### 3. Replace upgradeToToggleRecording with handleDoubleTap
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Replace the `upgradeToToggleRecording()` method (lines 92-102) with both methods:

```swift
/// Called synchronously from the CGEvent tap when a double-tap is detected.
/// Cancels any pending delayed stop and upgrades to toggle recording mode.
private func handleDoubleTap() {
    guard settings.toggleRecordingSettings.doubleTapEnabled else { return }

    pendingStopTask?.cancel()
    pendingStopTask = nil

    guard state == .recording else { return }
    guard !isToggleRecordingMode else { return }

    upgradeToToggleRecording()
}

/// Upgrades the current recording session to toggle mode.
/// Called from both double-tap detection and long press timer.
private func upgradeToToggleRecording() {
    isToggleRecordingMode = true
    ignoreNextKeyUp = true
    recordingIndicator.setToggleMode(true)
    Logger.app.info("Recording upgraded to toggle mode")
}
```

#### 4. Add long press timer in onHotkeyDown
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

After `recordingIndicator.show()` and before the race condition check (after `Logger.app.info("Push-to-talk: recording started")`), add:

```swift
// Start long-press timer — if user holds beyond the threshold,
// auto-upgrade to toggle recording mode.
if settings.toggleRecordingSettings.longPressEnabled {
    let threshold = Duration.seconds(settings.toggleRecordingSettings.longPressDuration)
    longPressTask?.cancel()
    longPressTask = Task { @MainActor in
        try? await Task.sleep(for: threshold)
        guard !Task.isCancelled else { return }
        guard self.state == .recording else { return }
        guard self.hotkeyManager.isHotkeyActive else { return }
        self.upgradeToToggleRecording()
    }
}
```

#### 5. Refactor stopRecordingAndTranscribe with delayed stop
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

Restructure `stopRecordingAndTranscribe()` to use delayed stop for non-toggle recordings. Extract the actual stop logic into `executeRecordingStop()`:

```swift
private func stopRecordingAndTranscribe() {
    Logger.app.debug("[stopRecordingAndTranscribe] enter — state=\(String(describing: self.state))")

    // Toggle mode: ignore the keyUp right after upgrading.
    // The user just upgraded (via double-tap or long press) and is releasing keys.
    if ignoreNextKeyUp {
        ignoreNextKeyUp = false
        Logger.app.debug("[stopRecordingAndTranscribe] ignoring keyUp after toggle upgrade")
        return
    }

    guard state == .recording else {
        Logger.app.debug("[stopRecordingAndTranscribe] state is not .recording, returning early")
        mediaPlaybackController.resumeIfNeeded()
        if state != .transcribing && state != .executing {
            recordingIndicator.hide()
        }
        return
    }

    // Cancel long press timer — user released before the threshold
    longPressTask?.cancel()
    longPressTask = nil

    if isToggleRecordingMode {
        // Toggle mode: stop immediately
        isToggleRecordingMode = false
        skipNextKeyDown = true
        recordingIndicator.setToggleMode(false)
        executeRecordingStop()
    } else if settings.toggleRecordingSettings.doubleTapEnabled {
        // Double-tap enabled: delay stop to allow double-tap upgrade.
        // Recording continues during this window so a double-tap
        // produces seamless recording without any gap.
        pendingStopTask?.cancel()
        pendingStopTask = Task { @MainActor in
            try? await Task.sleep(for: Self.doubleTapStopDelay)
            guard !Task.isCancelled else { return }
            guard self.state == .recording else { return }
            self.pendingStopTask = nil
            self.executeRecordingStop()
        }
    } else {
        // Double-tap disabled: stop immediately (zero latency)
        executeRecordingStop()
    }
}

/// Performs the actual recording stop: captures duration, stops audio,
/// transitions to transcribing, and kicks off the transcription pipeline.
private func executeRecordingStop() {
    let recordingDuration = recordingStartInstant.map { $0.duration(to: .now) }
    recordingStartInstant = nil

    guard let audioURL = audioRecorder.stopRecording() else {
        mediaPlaybackController.resumeIfNeeded()
        state = .error("No audio recorded")
        recordingIndicator.update(phase: .error, message: "No audio recorded")
        dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
        resetAfterDelay()
        return
    }

    state = .transcribing
    recordingIndicator.update(phase: .processing)
    Logger.app.info("Push-to-talk: transcribing...")

    // Resume media playback after stopping the mic. The delay lets CoreAudio
    // fully release the recording session so the output device is not contending
    // with an active input, which avoids degraded audio quality on resume.
    Task { @MainActor in
        try? await Task.sleep(for: Self.audioSettleDelayBeforeResume)
        self.mediaPlaybackController.resumeIfNeeded()
    }

    Task { @MainActor in await self.processTranscription(audioURL: audioURL, recordingDuration: recordingDuration) }
}
```

#### 6. Cancel pending stop in onHotkeyDown
**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

At the top of `onHotkeyDown()`, before the `skipNextKeyDown` check, cancel any pending stop. This handles the edge case where the delayed stop is still pending when a new recording starts:

```swift
// Cancel any pending delayed stop from a previous recording
pendingStopTask?.cancel()
pendingStopTask = nil
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] **Normal push-to-talk preserved:** Hold Control+/ → recording starts → release → recording stops after brief delay → transcription runs
- [ ] **Double-tap to toggle:** Tap Control+/ twice quickly → recording starts in toggle mode (red border) → release → recording continues → tap Control+/ → stops and transcribes
- [ ] **Long press to toggle:** Hold Control+/ for 2+ seconds → red border appears → release → recording continues → tap Control+/ → stops and transcribes
- [ ] **No key leak:** No "/" characters typed into the active app during any flow
- [ ] **No buzz on toggle stop:** Stopping a toggle recording does not trigger the shake animation
- [ ] **UI button still works:** Clicking the menu bar button starts/stops recording correctly

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful.

---

## Phase 3: Settings — Toggle Recording Configuration

### Overview
Add a `ToggleRecordingSettings` struct to `AppSettings` with enable/disable toggles for double-tap and long press, and a configurable long press duration. Add corresponding UI in `HomeTabView` right below the Push-to-Talk shortcut.

### Changes Required:

#### 1. Add ToggleRecordingSettings struct
**File**: `vcdr/Core/Settings/AppSettings.swift`

Add a new settings struct (after `AudioSettings`):

```swift
struct ToggleRecordingSettings: Codable, Equatable {
    var doubleTapEnabled: Bool
    var longPressEnabled: Bool
    /// Long press duration in seconds before auto-upgrading to toggle mode
    var longPressDuration: Double

    static let `default` = ToggleRecordingSettings(
        doubleTapEnabled: true,
        longPressEnabled: true,
        longPressDuration: 2.0
    )
}
```

#### 2. Add property and persistence to AppSettings
**File**: `vcdr/Core/Settings/AppSettings.swift`

Add a new stored property (after `audioSettings`):

```swift
var toggleRecordingSettings: ToggleRecordingSettings {
    didSet { save() }
}
```

Add a key in `Keys`:

```swift
static let toggleRecordingSettings = "toggleRecordingSettings"
```

In `init()`, load the settings (after audioSettings loading):

```swift
if let data = userDefaults.data(forKey: Keys.toggleRecordingSettings),
   let decoded = try? JSONDecoder().decode(ToggleRecordingSettings.self, from: data) {
    self.toggleRecordingSettings = decoded
} else {
    self.toggleRecordingSettings = .default
}
```

In `save()`, persist:

```swift
if let encoded = try? JSONEncoder().encode(toggleRecordingSettings) {
    userDefaults.set(encoded, forKey: Keys.toggleRecordingSettings)
}
```

#### 3. Add settings UI in HomeTabView
**File**: `vcdr/UI/HomeTabView.swift`

Add a new section right after the Push-to-Talk `ShortcutRecorderRow` (after line 94), inside the "Shortcuts" section:

```swift
Toggle("Double-tap to lock recording", isOn: Binding(
    get: { dependencies.settings.toggleRecordingSettings.doubleTapEnabled },
    set: { dependencies.settings.toggleRecordingSettings.doubleTapEnabled = $0 }
))
.font(.callout)

Toggle("Long press to lock recording", isOn: Binding(
    get: { dependencies.settings.toggleRecordingSettings.longPressEnabled },
    set: { dependencies.settings.toggleRecordingSettings.longPressEnabled = $0 }
))
.font(.callout)

if dependencies.settings.toggleRecordingSettings.longPressEnabled {
    HStack {
        Text("Hold duration")
            .font(.callout)
        Spacer()
        Picker("", selection: Binding(
            get: { dependencies.settings.toggleRecordingSettings.longPressDuration },
            set: { dependencies.settings.toggleRecordingSettings.longPressDuration = $0 }
        )) {
            Text("1s").tag(1.0)
            Text("1.5s").tag(1.5)
            Text("2s").tag(2.0)
            Text("3s").tag(3.0)
            Text("5s").tag(5.0)
        }
        .frame(width: 80)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Project builds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Settings toggles appear below Push-to-Talk shortcut
- [ ] Disabling double-tap removes the delayed stop (immediate push-to-talk release)
- [ ] Disabling long press prevents auto-upgrade when holding
- [ ] Changing long press duration is reflected in behavior
- [ ] Hold duration picker only shows when long press is enabled
- [ ] Settings persist across app restarts

---

## Testing Strategy

### Manual Testing Steps:
1. **Basic push-to-talk** — Hold shortcut, speak, release → transcription works (with ~400ms extra recording, imperceptible)
2. **Double-tap** — Tap shortcut twice quickly → toggle mode activates → red border appears → release → recording continues → tap to stop
3. **Long press** — Hold shortcut for 2+ seconds → red border appears → release → recording continues → tap to stop
4. **Rapid start-stop** — Do several quick push-to-talk recordings in succession → all work correctly, no stale state
5. **Double-tap then normal** — Do a double-tap toggle recording, stop it, then do a normal push-to-talk → both work correctly
6. **Long press then normal** — Do a long press toggle recording, stop it, then do a normal push-to-talk → both work correctly

## Edge Cases

- **Auto-repeat keyDown during hold:** `GlobalHotkeyManager` already filters auto-repeat events (`keyboardEventAutorepeat != 0`). Auto-repeat keyDowns are not counted as double-taps and don't fire callbacks.
- **Double-tap window expired but delayed stop pending:** If the second tap arrives after 400ms (not a double-tap), the delayed stop is still pending. The second tap's `onKeyDown` fires async. State is .recording (stop hasn't happened). `onHotkeyDown` returns early (not idle). The delayed stop fires normally. User can then start a new recording.
- **Long press + release + quick re-press:** If user holds for 1.5s, releases (delayed stop scheduled), and presses again within 400ms: the second press is NOT a double-tap (first keyDown was 1.5s ago). The async `onHotkeyDown` sees state is .recording (delayed stop pending) → returns early. Delayed stop fires normally.
- **UI button interaction:** `toggleRecording()` calls `stopRecordingAndTranscribe()` for stop, which handles toggle mode correctly. For start, it calls `onHotkeyDown()` without the long press timer (no hotkey hold involved).

## References

- `GlobalHotkeyManager.swift:80-128` — Current event handling with modifier detection (to be replaced)
- `RecordingCoordinator.swift:58-86` — Hotkey setup with modifier upgrade (to be replaced)
- `RecordingCoordinator.swift:92-102` — upgradeToToggleRecording method (to be refactored)
- `RecordingCoordinator.swift:209-264` — stopRecordingAndTranscribe (to be restructured)
- `AppSettings.swift:10-18` — AudioSettings struct (pattern for ToggleRecordingSettings)
- `HomeTabView.swift:77-129` — Shortcuts section (where toggle settings UI goes)
- Previous plan: `thoughts/shared/plans/2026-02-25-toggle-recording-mode.md`
