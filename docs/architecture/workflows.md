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
   value the Library and a Mode's naming key by, and say which
   `TranscriptionModelFamily` it belongs to — an existing one when it accepts
   exactly what that family accepts, a new one otherwise (`docs/adr/0020`)
2. Create a type conforming to `TranscriptionProvider` in `Transcription/`, and
   download its files under `TranscriptionModelRoot.url`. Run the download and
   the load inside `ModelPreparationQueue.takingTurn(urgency:whileHeldBack:)`,
   taking the queue the registry hands every provider: two models preparing at
   once make each other slower, and a model kept back says so by reporting
   `ModelPreparationPhase.waitingItsTurn`
3. Construct it in `TranscriptionProviderRegistry` and list the model in
   `offeredModels` — only what this platform's transcription path can drive.
   Another size of Whisper needs none of steps 1–2: add a case to
   `WhisperCheckpoint` naming the variant argmax publishes, and the registry
   offers it and hands it a `WhisperProvider` of its own. Only a multilingual
   checkpoint may join — the English-only ones take no Language Hint, and a
   family whose members disagree about a setting is not one family
4. Answer the Library's four questions in the provider: `installedDirectory`,
   `isInstalled`, `downloadProgress` (nil when the backend reports none) and
   `isInstallableOnThisDevice()`
5. For a new family, declare what it can be told in
   `TranscriptionModelFamily.capabilities` (`Shared/Transcription/`) — the kinds
   it accepts, or why it accepts nothing — and what its settings were stored
   under before it existed, in `keyBeforeFamilies`. Its settings screen is
   generated from that declaration, so a family with an unfamiliar hint needs a
   new `TranscriptionModelCapability` kind and its control in
   `TranscriptionModelSettingsView`, not a wider string list
6. Read what the run hands the provider in
   `transcribe(audioFileURL:settings:spellingHints:)` (iOS:
   `makeLiveSession(settings:spellingHints:)`), and only what the model
   declared. A Language Hint of `detect` must send no language at all — see
   `docs/adr/0019`. A model that declares `spellingHints` reads the
   Dictionary's `SpellingHints` and decides how to use them; Whisper puts them
   after the typed prompt through `WhisperPrompt` (`docs/adr/0025`). A model
   that does not declare it ignores them
7. Nothing else changes: the session resolves the model a run uses through
   `TranscriptionSettings.effectiveTranscription(for:)` — the active Mode's
   Transcription Override, else the Default — hands the provider the settings
   that came back, and the Library lists whatever `offeredModels` names

### Adding a setting a Transcription Model accepts
1. Add the field to `TranscriptionModelSettings` and a
   `TranscriptionModelCapability` kind for it (`Shared/Transcription/`), and
   declare the kind on every family that accepts it
2. Add a control for the kind in `TranscriptionModelSettingsView` — both the
   Transcription screen and a Mode's own section render from that one view
3. Add the field to `TranscriptionSettingsPatch` and to each of its per-field
   members — `applied(to:)`, `isSet`, `clear`, `record` — in
   `Shared/Transcription/TranscriptionOverride.swift`, so a Mode can set it for
   itself and give it back

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
2. **Accessibility** — for simulated paste (Cmd+V via CGEvent) and the Cursor Context read. Carbon hotkey claims need no grant, so every hotkey works without it. Nothing asks for the grant at launch: the first paste that finds the process untrusted shows the system dialog once (`AccessibilityGrant`), and the Home tab carries the standing notice.
3. **No App Sandbox** — required for the Accessibility APIs and for posting the simulated Cmd+V

## Things to Watch Out For

- **Clipboard operations may not be instant.** After `NSPasteboard.setString`, add a small delay before simulating Cmd+V. Document the delay with a comment.
- **Focus restoration timing.** After `NSRunningApplication.activate()`, a small delay is needed before sending keyboard events to that app.
- **Parakeet model is large** (its size is `TranscriptionModel.approximateSizeOnDisk`). First launch downloads it. Don't assume the model is ready — always check initialization state.
- **CGEvent requires accessibility.** Simulated paste won't work until the user grants accessibility permissions. Handle this gracefully with polling.
- **Audio recording at 16kHz mono.** This is Parakeet's native format. Don't change the sample rate — it avoids resampling overhead.

## iOS Testing Policy

- **Do not use iOS simulators.** Skip all `mcp__XcodeBuildMCP__*_sim` tools, `xcodebuild -destination 'platform=iOS Simulator...'`, and `simctl` for the iOS target. Simulators are disk-heavy and the maintainer tests on a physical device.
- When iOS verification is needed, ask the maintainer to run on their real device and report results. Plain `xcodebuild build` (no simulator destination) is acceptable for compile-only checks.
- macOS target is unaffected — build/run locally as normal.
