# ADR-0002: Shell-First Initialization

## Status

Accepted

## Context

On macOS, `AppDependencies.init()` was constructing every backend dependency synchronously during the SwiftUI `@State` initializer. This blocked the main thread before the `MenuBarExtra` or `Window` scenes could render their first frames.

Specifically, these calls ran in `init()`:

- `HistoryMigrator.reconcileAtLaunch()` — resolves the iCloud ubiquity container via `FileManager.url(forUbiquityContainerIdentifier:)`, which can block for seconds on first launch after install.
- `HistoryStoreFactory.make()` — either repeats the ubiquity lookup or synchronously scans the conversations directory and decodes JSON files.
- `AudioDeviceMonitor.init()` — queries `AVCaptureDevice.DiscoverySession`, which can stall on hardware enumeration.

The iOS app initially appeared to have solved the same problem by keeping
`RecordingFlowCoordinator()` lightweight and moving heavy work into `.task`.
Physical-device cold-launch traces later showed that this was incomplete:
detached CoreML specialization could still starve the main actor, persistent
logging performed synchronous first-use storage setup, and audio prewarm
incorrectly delayed the transition to transcription-ready state.

The iOS keyboard extension (`KeyboardViewController`) does not have this problem — its `viewDidLoad` is lightweight and all backend communication goes through the `KeyboardChannel`.

## Decision

We adopt **Shell-first Initialization** as a cross-platform guarantee: the visible shell renders before any backend dependency is initialized. Backend work is deferred to post-shell tasks, and readiness is surfaced asynchronously via state changes.

On macOS specifically:

1. `AppDependencies.init()` is limited to shell-critical work only (`AppSettings`, `SessionOverrides`, lightweight UI helpers, `StyleRegistry`).
2. All backend initialization (`HistoryMigrator`, `HistoryStoreFactory.make`, `AudioDeviceMonitor` hardware enumeration, transcription model download/compile) moves to the async `AppDependencies.initialize()` path.
3. When the user attempts recording before transcription is ready, the shell rejects the action with immediate visual feedback (orange indicator buzz + "Not ready" message) rather than accepting the action and blocking later.
4. History writes from `CaptureSession`/`TextProcessor` that arrive before the history store is ready are queued in memory and flushed once the store becomes available.
5. The menu bar tracks transcription readiness as the gating factor for recording. Other backends (history, audio devices) catch up in the background without blocking shell rendering.

On iOS specifically:

1. Automatic transcription-model initialization starts only after a short
   post-shell grace period and runs below interactive UI priority.
2. `Transcription Readiness` means that the speech-recognition model is ready.
   Audio-session and engine preparation are opportunistic follow-up work and do
   not delay the `READY` state.
3. A Recording Run may still begin before Transcription Readiness. Audio capture
   starts immediately and buffers until the model catches up.
4. Automatic launch work must not prompt for microphone permission. Permission
   is requested by explicit recording intent or by opting into a warm Hot Mic
   Session.
5. Persistent debug logging is best-effort. App Group storage initialization and
   file writes must never synchronously block the caller.
6. Audio route restart requests are serialized and coalesced. The app ignores
   its own speaker-output override notification while still responding to real
   device and route-configuration changes.

## Consequences

- The macOS app now matches the iOS initialization pattern: lightweight coordinator init, heavy work in `.task`.
- iOS launch work is split into shell-critical, transcription-readiness, and
  opportunistic audio-preparation phases rather than one `PREPARING` gate.
- First-launch menu bar icon appears immediately, even when iCloud container provisioning is still in progress.
- Users can open Settings and browse modes/destinations before transcription is ready, because `AppSettings` loads synchronously from UserDefaults.
- The recording hotkey is gated on `transcriptionProvider.isReady`; attempting to record while initializing produces a clear rejection instead of a silent hang at "Transcribing...".
- `CaptureSession` and `TextProcessor` must tolerate a history store that is not yet ready. A small queuing layer is needed for history writes.
- `AudioDeviceMonitor.refreshDevices()` must be called inside `initialize()` rather than `init()`, so the device list may be empty for a brief moment after launch.
