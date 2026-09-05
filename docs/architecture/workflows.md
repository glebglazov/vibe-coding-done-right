# Workflows, Permissions & Gotchas

## Adding New Features

### Adding a New Post-Transcription Action
1. Create a struct conforming to `PostTranscriptionAction` in `Actions/`
2. The action should handle its complete lifecycle (focus restoration, clipboard management, etc.) via init parameters
3. Add a case to `PostTranscriptionActionType` in `AppSettings.swift`
4. Update `RecordingCoordinator.makeAction()` to construct with context (target PID, mode settings)
5. Add UI in `SettingsView` for the new action type

### Adding a New Transcription Provider
1. Create a type conforming to `TranscriptionProvider` in `Transcription/`
2. Wire it through `AppDependencies`
3. The coordinator doesn't need to change — it uses the protocol

### Modifying the Global Hotkey
1. Update `AppSettings` if new settings are needed
2. Take `HotkeyRegistry` through the owner's init and claim the combination from it —
   the claim's lifetime is the hotkey's, so release the handle to give the
   combination back. No hotkey is on an event tap any more, and
   `GlobalHotkeyManager` has no users at all. Don't add to it.
3. Update `CaptureSession+Hotkeys.swift` for behavior changes to the session's own hotkeys

## Permissions Required

1. **Microphone** — for audio recording (`NSMicrophoneUsageDescription` in Info.plist)
2. **Accessibility** — for simulated paste (Cmd+V via CGEvent) and selection capture. Carbon hotkey claims need no grant, so every hotkey works without it.
3. **No App Sandbox** — required for CGEvent tap at `.cgSessionEventTap`

## Things to Watch Out For

- **Clipboard operations may not be instant.** After `NSPasteboard.setString`, add a small delay before simulating Cmd+V. Document the delay with a comment.
- **Focus restoration timing.** After `NSRunningApplication.activate()`, a small delay is needed before sending keyboard events to that app.
- **Parakeet model is large (~1.2GB).** First launch downloads it. Don't assume the model is ready — always check initialization state.
- **CGEvent requires accessibility.** Simulated paste won't work until the user grants accessibility permissions. Handle this gracefully with polling.
- **Audio recording at 16kHz mono.** This is Parakeet's native format. Don't change the sample rate — it avoids resampling overhead.

## iOS Testing Policy

- **Do not use iOS simulators.** Skip all `mcp__XcodeBuildMCP__*_sim` tools, `xcodebuild -destination 'platform=iOS Simulator...'`, and `simctl` for the iOS target. Simulators are disk-heavy and the maintainer tests on a physical device.
- When iOS verification is needed, ask the maintainer to run on their real device and report results. Plain `xcodebuild build` (no simulator destination) is acceptable for compile-only checks.
- macOS target is unaffected — build/run locally as normal.
