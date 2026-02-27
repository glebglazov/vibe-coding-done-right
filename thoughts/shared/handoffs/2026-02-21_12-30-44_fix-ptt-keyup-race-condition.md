---
date: 2026-02-21T12:30:44+0100
researcher: claude
git_commit: 7997b00460d40e924eae7bc58c4095d42f5fc509
branch: main
repository: vibe-coding-done-right
topic: "Fix PTT Hotkey KeyUp Race Condition"
tags: [implementation, hotkeys, recording, concurrency, CGEvent]
status: complete
last_updated: 2026-02-21
last_updated_by: claude
type: implementation_strategy
---

# Handoff: Fix PTT hotkey not stopping recording on quick release

## Task(s)

**Completed**: Fixed a bug where pressing and quickly releasing the push-to-talk hotkey would leave the app stuck in recording state (red waveform indicator visible, menu bar icon showing recording). The root cause was that the keyUp handler was dispatched through `DispatchQueue.main.async` → `Task { @MainActor }`, but the MainActor executor could stall for seconds (observed 10s delays), preventing the stop from firing.

The fix calls `onKeyUp` synchronously from the CGEvent tap callback, bypassing both GCD and MainActor scheduling entirely.

**Not implemented (discussed, deferred)**: Cancellation support — pressing the hotkey during `.transcribing` or `.executing` state to cancel and return to `.idle`. The user chose to defer this to a later session.

## Critical References
- `CLAUDE.md` — Architecture rules (no god objects, DI, no singletons, etc.)
- `thoughts/shared/plans/2026-02-21-fix-ptt-keyup-race-condition.md` — Original plan (note: plan describes earlier approaches that were superseded; the final fix is different)

## Recent changes

- `vcdr/Hotkeys/GlobalHotkeyManager.swift:12` — Made `isHotkeyActive` `private(set)` for coordinator to read
- `vcdr/Hotkeys/GlobalHotkeyManager.swift:14-18` — Added doc comment explaining `onKeyUp` is called synchronously from CGEvent tap
- `vcdr/Hotkeys/GlobalHotkeyManager.swift:98-106` — keyUp handler now calls `self.onKeyUp?()` synchronously instead of `DispatchQueue.main.async { self.onKeyUp?() }`
- `vcdr/Orchestration/RecordingCoordinator.swift:23` — Removed `isKeyDown` property (no longer needed)
- `vcdr/Orchestration/RecordingCoordinator.swift:44-55` — `onKeyUp` callback calls `stopRecordingAndTranscribe()` directly (no Task wrapper)
- `vcdr/Orchestration/RecordingCoordinator.swift:75` — Added `fromHotkey: Bool = false` parameter to `onHotkeyDown()`
- `vcdr/Orchestration/RecordingCoordinator.swift:109-118` — Race condition handler uses `hotkeyManager.isHotkeyActive` check (for when keyUp fires before `startRecording()` completes)
- `vcdr/Orchestration/RecordingCoordinator.swift:146` — Transcription Task explicitly `@MainActor` since `stopRecordingAndTranscribe()` can now be called from non-MainActor context

## Learnings

### MainActor executor can stall for seconds while the CFRunLoop keeps working
The macOS main thread has two scheduling layers: (1) CFRunLoop sources (CGEvent tap, timers) which fire during the run loop's source-handling phase, and (2) GCD main queue / MainActor executor which drains during a different phase. When the MainActor executor is stalled (possibly due to Swift Concurrency Task scheduling contention, `@Observable` tracking overhead, or CoreML work), CGEvent tap callbacks still fire promptly but `DispatchQueue.main.async` blocks and `Task { @MainActor }` can be delayed by 2-10+ seconds.

### The original `isKeyDown` flag approach was doubly broken
The coordinator's `isKeyDown` flag was set inside a `Task { @MainActor }` — subject to the same MainActor stalling. Replacing it with `hotkeyManager.isHotkeyActive` (set synchronously in the CGEvent tap) helps for the race condition case, but doesn't help when the MainActor is stalled (the check is inside the stalled Task). The synchronous `onKeyUp` callback is what actually fixed the primary issue.

### Debug logging was essential
Three iterations of fixes were needed. The first two (checking `isHotkeyActive` after await, using `CheckedContinuation`) failed because the underlying assumption was wrong — we assumed `continuation.resume()` would lead to prompt Task execution. Adding timestamped debug logging to both `GlobalHotkeyManager` and `RecordingCoordinator` revealed the true 10-second gap between `continuation.resume()` and Task execution.

## Artifacts
- `thoughts/shared/plans/2026-02-21-fix-ptt-keyup-race-condition.md` — Implementation plan (describes earlier approaches; final fix diverged)
- `vcdr/Hotkeys/GlobalHotkeyManager.swift` — Modified: synchronous keyUp dispatch
- `vcdr/Orchestration/RecordingCoordinator.swift` — Modified: removed `isKeyDown`, added `fromHotkey`, synchronous stop

## Action Items & Next Steps
- **Remove debug logging**: The `Logger.*.debug(...)` statements added for diagnosis (`[tap] keyDown fired`, `[onHotkeyDown] enter`, `[stopRecordingAndTranscribe] enter`, etc.) can be removed or kept at `.debug` level. They're useful for future diagnosis but add noise.
- **Cancellation support (deferred)**: Add ability to press hotkey during `.transcribing`/`.executing` to cancel and return to `.idle`. Requires storing the transcription `Task` and calling `.cancel()` on it.
- **Investigate MainActor stalling**: The root cause of WHY the MainActor executor stalls for seconds is unknown. Possible causes: CoreML/FluidAudio doing internal main-thread work during transcription, `@Observable` tracking overhead from high-frequency `audioLevel` updates (20Hz timer in `AudioRecorder.swift:85`), or SwiftUI view update contention. Profiling with Instruments would help.

## Other Notes
- The `onKeyDown` callback still uses `DispatchQueue.main.async` → `Task { @MainActor }`. This means keyDown can also be delayed. This hasn't been reported as a problem (users notice the stop failing, not the start being delayed), but it's worth knowing.
- `stopRecordingAndTranscribe()` is now called from two contexts: (1) the CGEvent tap callback (synchronous, via `onKeyUp`), and (2) MainActor Tasks (via `toggleRecording()` UI button and the `isHotkeyActive` race condition handler in `onHotkeyDown`). The `Task { @MainActor in ... }` for transcription ensures it always runs on MainActor regardless of calling context.
- Parakeet transcription requires at least 1 second of audio. Very quick press-release often results in "No speech detected" or "Invalid audio data" errors, which is expected behavior.
