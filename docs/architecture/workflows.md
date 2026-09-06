# Workflows, Permissions & Gotchas

## Adding New Features

### Adding a New Post-Transcription Action
1. Create a struct conforming to `PostTranscriptionAction` in `Actions/`
2. The action should handle its complete lifecycle (focus restoration, clipboard management, etc.) via init parameters
3. Add a case to `PostTranscriptionActionType` in `AppSettings.swift`
4. Update `RecordingCoordinator.makeAction()` to construct with context (target PID, mode settings)
5. Add UI in `SettingsView` for the new action type

### Adding a New Transcription Model
1. Add a case to `TranscriptionModel` in `Shared/Transcription/`, with the raw
   value settings and overrides key by
2. Create a type conforming to `TranscriptionProvider` in `Transcription/`, and
   download its files under `TranscriptionModelRoot.url`
3. Construct it in `TranscriptionProviderRegistry` and list the model in
   `offeredModels` — only what this platform's transcription path can drive
4. Nothing else changes: the session resolves the Default's provider through the
   protocol

### Modifying the Global Hotkey
1. Update `AppSettings` if new settings are needed
2. Take `HotkeyRegistry` through the owner's init and claim the combination from it —
   the claim's lifetime is the hotkey's, so release the handle to give the
   combination back. This is the app's only key-press mechanism; there is no event
   tap left to fall back on.
3. Update `CaptureSession+Hotkeys.swift` for behavior changes to the session's own hotkeys
4. Don't give the owner a "suppressed" flag. The registry it claims through is a
   `SuspendableHotkeyRegistry`, and `AppDependencies.suspendHotkeys()` hands every
   claim back for as long as the returned `HotkeySuspension` is held — which is how
   the shortcut recorder reads a bound combination. An owner claims and releases on
   its own state only, and gets its claim back when the Suspension ends.

## Permissions Required

1. **Microphone** — for audio recording (`NSMicrophoneUsageDescription` in Info.plist)
2. **Accessibility** — for simulated paste (Cmd+V via CGEvent) and selection capture. Carbon hotkey claims need no grant, so every hotkey works without it. Nothing asks for the grant at launch: the first paste that finds the process untrusted shows the system dialog once (`AccessibilityGrant`), and the Home tab carries the standing notice.
3. **No App Sandbox** — required for the Accessibility APIs and for posting the simulated Cmd+V

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
