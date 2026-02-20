---
date: 2026-02-20T00:28:05+0100
researcher: claude
git_commit: 42971b5
branch: main
repository: vibe-coding-done-right
topic: "Audio Device Selector, Mode Switcher, and Dictation Terminator"
tags: [implementation, audio, modes, hotkeys, terminator]
status: complete
last_updated: 2026-02-20
last_updated_by: claude
type: implementation_strategy
---

# Handoff: VCDR Audio, Mode Switcher, and Dictation Terminator

## Task(s)

### Completed
1. **Audio device selector and sound check** — Added Audio section to Home tab with input device picker (dynamically updated on connect/disconnect) and opt-in sound check level meter. Sound check is off by default; user clicks "Test" to start and "Stop" to stop.
2. **Removed automatic permission prompts** — App no longer prompts for mic/accessibility on startup. Users grant via Home tab buttons.
3. **Fixed duplicate Sound Check label** — AudioLevelMeter had its own wrapping label.
4. **Mode switcher popup with global hotkey** — Floating popup at top-center (same position as recording indicator) showing all modes with keyboard nav (j/k, arrows, 1-9 number keys, Enter, Escape) and mouse hover/click. Triggered via configurable global hotkey or clicking mode name below recording button.
5. **Refactored hotkey storage** — Combined `hotkeyKeyCode`/`hotkeyModifiers` into `HotkeyBinding` struct with `pushToTalkHotkey` and `modeSwitcherHotkey` properties.
6. **Always-visible shortcut clear button** — X button for clearing shortcuts is always rendered but disabled when no shortcut is assigned.

### Planned/Discussed (not started)
7. **Dictation terminator per mode** — User was describing this feature when the session ended. The idea: each mode should have a configurable "terminator" string that gets appended to transcription if it doesn't already end with punctuation (`.`, `?`, `!`). Currently `PasteAction.prefixIfNeeded()` hardcodes `". "` as a separator. The new feature would:
   - Add a `terminator` field to `Mode` (e.g. `". "`, `".\n"`, `" "`, or empty to disable)
   - Support special syntax: `<space>` and `<newline>` tokens for user-friendly editing
   - Replace the hardcoded `". "` in `PasteAction` with the mode's terminator
   - Apply to both paste and bash actions (pass terminated text to action)
   - Show a text field in `ModeDetailView` for editing the terminator

   **No plan file was written yet.** The user interrupted the `/create_plan` to create this handoff instead.

## Critical References
- `mac/CLAUDE.md` — Architecture rules (no god objects, 300-line limit, 5 observable property limit, DI, OSLog, no magic numbers)
- `thoughts/shared/plans/2026-02-20-mode-switcher-popup.md` — Mode switcher plan (fully implemented)

## Recent changes

All changes are on `main` branch across these commits:
- `2a3196c` — Audio device selector and sound check (`AudioDeviceMonitor.swift`, `InputLevelMonitor.swift`, `AudioSectionView.swift`, `AppSettings.swift`, `AppDependencies.swift`, `Logger+Extensions.swift`, `HomeTabView.swift`)
- `10442c5` — Remove automatic permission prompts (`AppDependencies.swift`)
- `7a2d587` — Fix duplicate Sound Check label (`AudioSectionView.swift`)
- `42971b5` — Mode switcher popup (`AppSettings.swift`, `ShortcutRecorderRow.swift`, `ModeSwitcherPanel.swift`, `ModeSwitcherCoordinator.swift`, `AppDependencies.swift`, `HomeTabView.swift`, `MenuBarView.swift`, `PushToTalkCoordinator.swift`)

## Learnings

- **NSPanel focus for keyboard events**: `.nonactivatingPanel` panels don't receive keyboard events by default. Need to subclass `NSPanel` overriding `canBecomeKey -> true`, call `makeKey()`, and use `NSEvent.addLocalMonitorForEvents` for key handling instead of SwiftUI's `.onKeyPress`. See `ModeSwitcherPanel.swift:100-102` for the `KeyablePanel` subclass.
- **AppSettings property limit**: CLAUDE.md limits observable properties to 5. Currently at exactly 5: `pushToTalkHotkey`, `modeSwitcherHotkey`, `modes`, `activeModeID`, `preferredInputDeviceID`. Adding `terminator` to `Mode` struct (not AppSettings) avoids this limit.
- **Inner git repo**: There was a stale `.git` directory at `mac/vcdr/.git` that was removed. The real git root is at `mac/`.
- **AVCaptureDevice notifications**: Use `AVCaptureDevice.wasConnectedNotification` / `.wasDisconnectedNotification` (not the deprecated `NSNotification.Name` versions) for macOS 15+.
- **CoreAudio pointer safety**: `AudioValueTranslation` requires `withUnsafeMutablePointer` wrappers to avoid pointer lifetime warnings. See `InputLevelMonitor.swift:101-119`.

## Artifacts

- `vcdr/vcdr/Audio/AudioDeviceMonitor.swift` — Device enumeration with dynamic connect/disconnect observation
- `vcdr/vcdr/Audio/InputLevelMonitor.swift` — AVAudioEngine-based RMS level monitor with CoreAudio device selection
- `vcdr/vcdr/UI/AudioSectionView.swift` — Audio section with device picker and level meter
- `vcdr/vcdr/UI/ModeSwitcherPanel.swift` — Floating mode switcher with KeyablePanel, NSEvent key monitor, hover/click
- `vcdr/vcdr/Orchestration/ModeSwitcherCoordinator.swift` — Hotkey + panel lifecycle
- `vcdr/vcdr/Core/Settings/AppSettings.swift` — `HotkeyBinding` struct, `pushToTalkHotkey`, `modeSwitcherHotkey`
- `thoughts/shared/plans/2026-02-20-mode-switcher-popup.md` — Completed plan

## Action Items & Next Steps

1. **Create plan for dictation terminator** — Run `/create_plan` with the user's requirements:
   - Per-mode `terminator` field on `Mode` struct (default: `". "` for backward compat)
   - Support `<space>` and `<newline>` display tokens in the UI text field
   - Replace hardcoded `". "` in `PasteAction.prefixIfNeeded()` with mode's terminator
   - Decide: should terminator logic live in the coordinator (before passing to action) or in each action? Coordinator makes more sense since it applies to both paste and bash.
   - Decide: should the "prepend if existing text" behavior stay, or should terminators always append to transcription regardless?
   - Add UI in `ModeDetailView` for editing the terminator string

2. **Implement the terminator plan** once approved.

## Other Notes

- The git repo root is at `mac/` (not `mac/vcdr/`). Build command must run from `mac/vcdr/`: `cd mac/vcdr && xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- `PasteAction` currently has two behaviors intertwined: (1) detecting existing text via accessibility APIs and (2) prepending `". "`. The terminator feature should cleanly separate these concerns.
- `BashAction` passes text via `$VCDR_TEXT` env var. If terminator is applied in the coordinator before the action, bash scripts get the terminated text automatically.
- `Mode` is `Codable` — adding a new field requires a default value for backward compat with existing UserDefaults data. Use `init(from:)` with `decodeIfPresent` or give the property a default.
