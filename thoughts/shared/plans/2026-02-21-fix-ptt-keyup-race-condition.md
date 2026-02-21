# Fix PTT keyUp Race Condition

## Overview

The push-to-talk hotkey fails when the user presses and releases quickly. The recording indicator stays visible and subsequent hotkey presses are ignored. Root cause: the keyUp event is dispatched asynchronously (`DispatchQueue.main.async` → `Task { @MainActor }`), so the `isKeyDown` flag may not be updated by the time the `startRecording()` await completes and the race condition handler checks it.

## Current State Analysis

### The dispatch chain

```
Physical key event
  → CGEvent tap callback (main run loop, synchronous)
  → GlobalHotkeyManager.handleEvent()
  → isHotkeyActive = true/false          ← SYNCHRONOUS, immediate
  → DispatchQueue.main.async { onKeyDown/Up?() }
  → Task { @MainActor in ... }           ← ASYNCHRONOUS, queued
  → RecordingCoordinator method
```

`GlobalHotkeyManager.isHotkeyActive` (line 12) reflects the real-time physical key state — it's set synchronously in the CGEvent tap callback before any dispatch. But `RecordingCoordinator.isKeyDown` (line 24) is set inside async Tasks, which may execute out of order relative to other async operations.

### The bug scenario (quick press-release)

1. keyDown → `isHotkeyActive = true` (sync) → dispatches `onHotkeyDown()` Task
2. keyUp → `isHotkeyActive = false` (sync) → dispatches `stopRecordingAndTranscribe()` Task
3. `onHotkeyDown()` Task runs: `isKeyDown = true`, `await startRecording()` → **suspends**
4. `stopRecordingAndTranscribe()` Task **may or may not run** during suspension (depends on MainActor scheduling)
5. `startRecording()` completes → `state = .recording` → shows indicator → checks `!isKeyDown`
6. If step 4 didn't run: `isKeyDown` is still `true` → race condition handler **does NOT fire** → recording continues with indicator visible
7. `stopRecordingAndTranscribe()` Task eventually runs → stops recording → transcription starts
8. During transcription (CoreML likely blocks main thread), all subsequent hotkey events queue up

### Key Discoveries

- `GlobalHotkeyManager.isHotkeyActive` (`GlobalHotkeyManager.swift:12`) is set synchronously in the tap callback — it's always up-to-date
- `RecordingCoordinator.isKeyDown` (`RecordingCoordinator.swift:24`) is set asynchronously via Tasks — it may be stale after an `await`
- The race condition handler at `RecordingCoordinator.swift:108` checks `isKeyDown` but should check `isHotkeyActive`
- The race condition check is only relevant for hotkey-triggered recording, not UI toggle (`toggleRecording()`)

## Desired End State

After the fix, pressing and quickly releasing the PTT hotkey reliably stops recording. The recording indicator appears briefly and disappears. The race condition handler uses the synchronous `isHotkeyActive` flag from the CGEvent tap instead of the async `isKeyDown` flag.

### Verification

- Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- Quick press-release: indicator flashes briefly then disappears, transcription runs
- Normal hold-and-release: recording continues while held, stops on release
- UI toggle button: still works (click to start, click to stop)

## What We're NOT Doing

- Adding cancellation support for transcription (Phase 2, deferred)
- Changing the `DispatchQueue.main.async` dispatch mechanism in `GlobalHotkeyManager`
- Investigating CoreML main-thread blocking during transcription

## Implementation

### 1. Expose `isHotkeyActive` on `GlobalHotkeyManager`

**File**: `vcdr/Hotkeys/GlobalHotkeyManager.swift`

Change line 12 from `private` to `private(set)`:

```swift
// Before:
private var isHotkeyActive = false

// After:
private(set) var isHotkeyActive = false
```

### 2. Fix race condition check in `RecordingCoordinator`

**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

**2a. Remove `isKeyDown` property** (line 24):

```swift
// Remove this line:
private var isKeyDown = false
```

**2b. Add `fromHotkey` parameter to `onHotkeyDown`** (line 78):

```swift
// Before:
private func onHotkeyDown() async {

// After:
private func onHotkeyDown(fromHotkey: Bool = false) async {
```

**2c. Replace the race condition handler** (lines 95, 107-111):

```swift
// Before:
isKeyDown = true
previousActiveApp = NSWorkspace.shared.frontmostApplication

let started = await audioRecorder.startRecording()
if started {
    state = .recording
    recordingIndicator.show()
    if settings.audioSettings.pauseMediaDuringRecording {
        mediaPlaybackController.pauseIfNeeded()
    }
    Logger.app.info("Push-to-talk: recording started")

    // If key was released while we were starting, immediately stop
    if !isKeyDown {
        Logger.app.info("Key released during setup, stopping immediately")
        stopRecordingAndTranscribe()
    }
} else {
    isKeyDown = false
    state = .error("Failed to start recording")
    Logger.app.error("Push-to-talk: failed to start recording")
    resetAfterDelay()
}

// After:
previousActiveApp = NSWorkspace.shared.frontmostApplication

let started = await audioRecorder.startRecording()
if started {
    state = .recording
    recordingIndicator.show()
    if settings.audioSettings.pauseMediaDuringRecording {
        mediaPlaybackController.pauseIfNeeded()
    }
    Logger.app.info("Push-to-talk: recording started")

    // If hotkey was released while we were awaiting startRecording(), stop immediately.
    // Uses hotkeyManager.isHotkeyActive (set synchronously in the CGEvent tap callback)
    // instead of an async flag, which may not have been updated yet.
    // Only relevant for hotkey-triggered recording — UI toggle has no keyUp event.
    if fromHotkey && !hotkeyManager.isHotkeyActive {
        Logger.app.info("Key released during setup, stopping immediately")
        stopRecordingAndTranscribe()
    }
} else {
    state = .error("Failed to start recording")
    Logger.app.error("Push-to-talk: failed to start recording")
    resetAfterDelay()
}
```

**2d. Remove `isKeyDown = false` from `stopRecordingAndTranscribe`** (line 125):

```swift
// Before:
private func stopRecordingAndTranscribe() {
    isKeyDown = false
    recordingIndicator.hide()

// After:
private func stopRecordingAndTranscribe() {
    recordingIndicator.hide()
```

### 3. Update callers to pass `fromHotkey`

**File**: `vcdr/Orchestration/RecordingCoordinator.swift`

**3a. In `setupHotkey`**, update the `onKeyDown` closure (line 48):

```swift
// Before:
await self?.onHotkeyDown()

// After:
await self?.onHotkeyDown(fromHotkey: true)
```

**3b. `toggleRecording`** (line 68) — no change needed, uses default `fromHotkey: false`.

## Success Criteria

### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

### Manual Verification:
- [ ] Quick press-release of PTT hotkey: recording indicator flashes briefly then disappears, transcription starts normally
- [ ] Normal hold-and-release: recording continues while key is held, stops on release, transcription runs
- [ ] Multiple quick presses: each one starts and stops correctly
- [ ] UI toggle button: click to start recording, click again to stop — still works
- [ ] Hotkey during transcription: still logs warning (no cancellation yet), but at least recording stops reliably before transcription begins
