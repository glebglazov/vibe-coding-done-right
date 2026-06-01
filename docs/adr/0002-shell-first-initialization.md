# ADR-0002: Shell-First Initialization

## Status

Accepted

## Context

On macOS, `AppDependencies.init()` was constructing every backend dependency synchronously during the SwiftUI `@State` initializer. This blocked the main thread before the `MenuBarExtra` or `Window` scenes could render their first frames.

Specifically, these calls ran in `init()`:

- `HistoryMigrator.reconcileAtLaunch()` — resolves the iCloud ubiquity container via `FileManager.url(forUbiquityContainerIdentifier:)`, which can block for seconds on first launch after install.
- `HistoryStoreFactory.make()` — either repeats the ubiquity lookup or synchronously scans the conversations directory and decodes JSON files.
- `AudioDeviceMonitor.init()` — queries `AVCaptureDevice.DiscoverySession`, which can stall on hardware enumeration.

The iOS app had already solved the same problem by keeping `RecordingFlowCoordinator()` lightweight and moving all heavy work into `.task`. The macOS and iOS apps share the same product goals but had diverged on initialization architecture.

The iOS keyboard extension (`KeyboardViewController`) does not have this problem — its `viewDidLoad` is lightweight and all backend communication goes through the `KeyboardChannel`.

## Decision

We adopt **Shell-first Initialization** as a cross-platform guarantee: the visible shell renders before any backend dependency is initialized. Backend work is deferred to post-shell tasks, and readiness is surfaced asynchronously via state changes.

On macOS specifically:

1. `AppDependencies.init()` is limited to shell-critical work only (`AppSettings`, `SessionOverrides`, lightweight UI helpers, `StyleRegistry`).
2. All backend initialization (`HistoryMigrator`, `HistoryStoreFactory.make`, `AudioDeviceMonitor` hardware enumeration, transcription model download/compile) moves to the async `AppDependencies.initialize()` path.
3. When the user attempts recording before transcription is ready, the shell rejects the action with immediate visual feedback (orange indicator buzz + "Not ready" message) rather than accepting the action and blocking later.
4. History writes from `CaptureSession`/`TextProcessor` that arrive before the history store is ready are queued in memory and flushed once the store becomes available.
5. The menu bar tracks transcription readiness as the gating factor for recording. Other backends (history, audio devices) catch up in the background without blocking shell rendering.

## Consequences

- The macOS app now matches the iOS initialization pattern: lightweight coordinator init, heavy work in `.task`.
- First-launch menu bar icon appears immediately, even when iCloud container provisioning is still in progress.
- Users can open Settings and browse modes/destinations before transcription is ready, because `AppSettings` loads synchronously from UserDefaults.
- The recording hotkey is gated on `transcriptionProvider.isReady`; attempting to record while initializing produces a clear rejection instead of a silent hang at "Transcribing...".
- `CaptureSession` and `TextProcessor` must tolerate a history store that is not yet ready. A small queuing layer is needed for history writes.
- `AudioDeviceMonitor.refreshDevices()` must be called inside `initialize()` rather than `init()`, so the device list may be empty for a brief moment after launch.
