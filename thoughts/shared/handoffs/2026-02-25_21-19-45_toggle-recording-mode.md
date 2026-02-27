---
date: 2026-02-25T21:19:45+0100
researcher: claude
git_commit: ee12edbe31f387da8295186f242409da8948ed22
branch: main
repository: vibe-coding-done-right
topic: "Toggle Recording Mode (Start/Stop) via Double-Tap and Long Press"
tags: [implementation, hotkeys, recording, toggle-mode, settings]
status: complete
last_updated: 2026-02-25
last_updated_by: claude
type: implementation_strategy
---

# Handoff: Toggle Recording Mode (Start/Stop)

## Task(s)

### 1. Toggle recording mode with modifier upgrade (COMPLETED - but needs replacement)
Implemented a toggle recording mode where holding push-to-talk and pressing an additional modifier key upgrades the session to toggle mode. **This approach has a bug**: macOS re-sends keyDown events with updated modifier flags, causing the non-modifier key (e.g., "/") to leak into the active app. The code is committed to the working tree (not yet committed to git).

### 2. Replace modifier upgrade with double-tap + long press (PLANNED - ready for implementation)
Created an implementation plan to replace the modifier approach with two deterministic triggers:
- **Double-tap**: Tap push-to-talk twice quickly (< 400ms) to enter toggle mode
- **Long press**: Hold push-to-talk for a configurable duration (default 2s) to auto-upgrade

The plan has 3 phases and is ready for implementation.

## Critical References
- Implementation plan: `thoughts/shared/plans/2026-02-25-toggle-recording-double-tap-long-press.md` — the authoritative plan to implement
- Original (superseded) plan: `thoughts/shared/plans/2026-02-25-toggle-recording-mode.md` — for context only, do NOT implement this

## Recent changes

**Uncommitted changes in working tree** (from the modifier-based approach — Phase 1 of the original plan):

- `vcdr/Hotkeys/GlobalHotkeyManager.swift:20-23` — Added `onModifierUpgrade` callback and `.flagsChanged` event mask (to be REPLACED with `onDoubleTap` and `lastKeyDownTime`)
- `vcdr/Hotkeys/GlobalHotkeyManager.swift:114-125` — Added flagsChanged handler (to be REPLACED with double-tap detection in keyDown handler)
- `vcdr/Orchestration/RecordingCoordinator.swift:30-36` — Added toggle state flags: `isToggleRecordingMode`, `ignoreNextKeyUp`, `skipNextKeyDown` (KEEP these)
- `vcdr/Orchestration/RecordingCoordinator.swift:81-83` — Wired `onModifierUpgrade` (to be REPLACED with `onDoubleTap`)
- `vcdr/Orchestration/RecordingCoordinator.swift:92-102` — Added `upgradeToToggleRecording()` method (to be REFACTORED — split into `handleDoubleTap()` + `upgradeToToggleRecording()`)
- `vcdr/Orchestration/RecordingCoordinator.swift:121-133` — Added `skipNextKeyDown` and toggle-mode checks in `onHotkeyDown()` (KEEP, but add `pendingStopTask` cancellation)
- `vcdr/Orchestration/RecordingCoordinator.swift:209-240` — Modified `stopRecordingAndTranscribe()` with `ignoreNextKeyUp` check and toggle cleanup (to be RESTRUCTURED with delayed stop + `executeRecordingStop()`)
- `vcdr/UI/RecordingIndicator.swift:22` — Added `isToggleMode` to `IndicatorPhaseState` (KEEP)
- `vcdr/UI/RecordingIndicator.swift:44` — Reset toggle mode in `show()` (KEEP)
- `vcdr/UI/RecordingIndicator.swift:90-92` — Added `setToggleMode()` method (KEEP)
- `vcdr/UI/RecordingIndicator.swift:112-114` — Added toggle border/glow constants (KEEP)
- `vcdr/UI/RecordingIndicator.swift:128-140` — Added red border overlay and glow shadow on circle (KEEP)
- `vcdr/UI/RecordingIndicator.swift:187` — Added toggle mode animation (KEEP)

## Learnings

1. **macOS re-sends keyDown events when modifiers change during a key hold**. If you're holding Control+/ and press Option, macOS sends a new keyDown for / with Control+Option flags. The CGEvent tap's exact-match modifier check passes it through to the app. This is why the modifier-based upgrade approach doesn't work.

2. **CGEvent tap callback synchronous ordering guarantee**: Both `onKeyUp` and `onDoubleTap` are called synchronously from the CGEvent tap callback on the main run loop. Any Task scheduled (like the delayed stop) cannot execute until the callback returns and the run loop iterates. This guarantees that a double-tap cancellation always happens before the delayed stop fires — no race conditions.

3. **Delayed stop trade-off**: When double-tap is enabled, normal push-to-talk has ~400ms extra recording time (delayed stop). This is imperceptible but should be configurable — when the user disables double-tap in settings, the delayed stop should also be disabled for zero-latency push-to-talk release.

4. **Three boolean flags manage toggle state**: `isToggleRecordingMode` (whether in toggle mode), `ignoreNextKeyUp` (skip keyUp after upgrade), `skipNextKeyDown` (skip stale async keyDown after toggle stop). This pattern works for both double-tap and long-press upgrade paths.

## Artifacts

- `thoughts/shared/plans/2026-02-25-toggle-recording-double-tap-long-press.md` — **Primary plan to implement** (3 phases: GlobalHotkeyManager double-tap, RecordingCoordinator delayed stop + long press, Settings UI)
- `thoughts/shared/plans/2026-02-25-toggle-recording-mode.md` — Original modifier-based plan (superseded, for reference only)
- Modified files listed in "Recent changes" above (uncommitted)

## Action Items & Next Steps

1. **Implement Phase 1** of `thoughts/shared/plans/2026-02-25-toggle-recording-double-tap-long-press.md`:
   - In `GlobalHotkeyManager.swift`: Remove `onModifierUpgrade`, remove `.flagsChanged` from event mask, remove flagsChanged handler. Add `onDoubleTap` callback, `lastKeyDownTime` tracking, and double-tap detection in the keyDown handler.

2. **Implement Phase 2** — RecordingCoordinator changes:
   - Replace `onModifierUpgrade` wiring with `onDoubleTap` in `setupHotkey()`
   - Add `handleDoubleTap()` method (cancels pending stop, calls `upgradeToToggleRecording()`)
   - Add `pendingStopTask` and `longPressTask` properties
   - Restructure `stopRecordingAndTranscribe()` with delayed stop for non-toggle, immediate for toggle, settings-conditional
   - Extract `executeRecordingStop()` with the actual stop logic
   - Add long press timer in `onHotkeyDown()` (settings-conditional, uses configurable duration)
   - Add `pendingStopTask` cancellation at top of `onHotkeyDown()`

3. **Implement Phase 3** — Settings:
   - Add `ToggleRecordingSettings` struct to `AppSettings.swift` (doubleTapEnabled, longPressEnabled, longPressDuration)
   - Add persistence (UserDefaults key, load in init, save)
   - Add UI in `HomeTabView.swift` below Push-to-Talk shortcut (two toggles + duration picker)

4. **Build verification**: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

5. **Manual testing**: All flows described in the plan's Testing Strategy section

## Other Notes

- The indicator visual changes (red border + glow for toggle mode) are already implemented and working. They are driven by `IndicatorPhaseState.isToggleMode` and `RecordingIndicatorPanel.setToggleMode()`. No changes needed in Phase 3 of the new plan.
- The `RecordingCoordinator` is NOT `@MainActor` but all its state is accessed from the main thread (CGEvent tap runs on main run loop, async handlers go through MainActor Tasks). This is intentional — the synchronous keyUp path avoids MainActor executor stalls.
- The user's current push-to-talk shortcut is Control+/ (customized from the default Cmd+Option+Space).
- `longPressThreshold` should be read from settings (`settings.toggleRecordingSettings.longPressDuration`) rather than a static constant, since it's user-configurable. The `doubleTapStopDelay` (400ms) and `doubleTapWindow` (400ms) remain static constants.
