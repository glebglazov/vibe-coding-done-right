# Pause Media During Recording + Audio Tab

## Overview

Add a feature that pauses system media playback when push-to-talk recording starts and resumes it when recording stops. Reorganize the UI to create a dedicated Audio tab containing microphone settings and the new media interaction toggle.

## Current State Analysis

- Audio settings (device picker, sound check) live in `HomeTabView` via `AudioSectionView`
- `AppSettings` has 5 observable properties (at the CLAUDE.md limit): `pushToTalkHotkey`, `modeSwitcherHotkey`, `modes`, `activeModeID`, `preferredInputDeviceID`
- `PushToTalkCoordinator.stopRecordingAndTranscribe()` is the point where the mic stops being used
- The app is already non-sandboxed (CGEvent tap for hotkeys), so CGEvent media key simulation works without extra permissions
- `MainWindowView.Tab` enum has 3 cases: `.home`, `.modes`, `.transcription`

### Key Discoveries:
- `AudioDeviceMonitor` reads/writes `settings.preferredInputDeviceID` at `AudioDeviceMonitor.swift:29-30`
- `HomeTabView` manages level monitor lifecycle via `onDisappear` and `onChange` at lines 134-142
- Media play/pause key is `NX_KEYTYPE_PLAY = 16`, posted as `NSEvent.EventType.systemDefined` with subtype 8
- No public macOS API to detect if media is playing — CGEvent is toggle-only

## What We're NOT Doing

- State-aware pause via AppleScript (Spotify/Apple Music only, adds Automation permission prompt)
- MediaRemote private framework (broken for third parties since macOS 15.4)
- Detecting whether media was actually playing before pausing

## Approach

**Media pause:** Simulate the system play/pause media key via CGEvent. On recording start, send play/pause (pauses if playing). On recording stop, send play/pause again (resumes). Simple, universal, works with any media app.

**Settings limit:** Combine `preferredInputDeviceID` with the new `pauseMediaDuringRecording` into an `AudioSettings` struct, replacing one observable property with a struct — stays at 5.

**UI:** New Audio tab with two sections: "Microphone" (moved from Home) and "Interaction with OS" (new toggle).

## Phase 1: AudioSettings struct + MediaPlaybackController

### 1a. Create `AudioSettings` struct

**File**: `vcdr/vcdr/Core/Settings/AppSettings.swift`

Add struct and replace `preferredInputDeviceID` with `audioSettings`:

```swift
struct AudioSettings: Codable, Equatable {
    var preferredInputDeviceID: String?
    var pauseMediaDuringRecording: Bool

    static let `default` = AudioSettings(
        preferredInputDeviceID: nil,
        pauseMediaDuringRecording: true
    )
}
```

In `AppSettings`:
- Replace `var preferredInputDeviceID: String?` with `var audioSettings: AudioSettings`
- Update `init` to load from new key (with fallback to legacy `preferredInputDeviceID` key)
- Update `save()` to encode the struct

### 1b. Update references to `preferredInputDeviceID`

**File**: `vcdr/vcdr/Audio/AudioDeviceMonitor.swift`
- Change `settings.preferredInputDeviceID` → `settings.audioSettings.preferredInputDeviceID` (lines 29-30)

### 1c. Create `MediaPlaybackController`

**New file**: `vcdr/vcdr/Audio/MediaPlaybackController.swift` (~40 lines)

```swift
import AppKit
import OSLog

@MainActor
final class MediaPlaybackController {
    private var didSendPause = false

    // MARK: - Constants
    private static let mediaPlayPauseKeyCode: Int32 = 16  // NX_KEYTYPE_PLAY

    func pauseIfNeeded() {
        didSendPause = true
        Self.sendMediaKeyEvent()
        Logger.audio.info("Sent media pause key")
    }

    func resumeIfNeeded() {
        guard didSendPause else { return }
        didSendPause = false
        Self.sendMediaKeyEvent()
        Logger.audio.info("Sent media resume key")
    }

    private static func sendMediaKeyEvent() {
        let keyCode = mediaPlayPauseKeyCode

        // Key down
        let downFlags: UInt32 = 0xA00
        let downData1 = Int((keyCode << 16) | Int32(bitPattern: downFlags))
        let downEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(downFlags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: downData1,
            data2: -1
        )
        downEvent?.cgEvent?.post(tap: .cghidEventTap)

        // Key up
        let upFlags: UInt32 = 0xB00
        let upData1 = Int((keyCode << 16) | Int32(bitPattern: upFlags))
        let upEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(upFlags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: upData1,
            data2: -1
        )
        upEvent?.cgEvent?.post(tap: .cghidEventTap)
    }
}
```

### 1d. Wire into AppDependencies

**File**: `vcdr/vcdr/App/AppDependencies.swift`

- Add `let mediaPlaybackController = MediaPlaybackController()`
- Update `PushToTalkCoordinator` init to receive it

### 1e. Integrate into PushToTalkCoordinator

**File**: `vcdr/vcdr/Orchestration/PushToTalkCoordinator.swift`

- Add `mediaPlaybackController` and `settings` reference for the audio setting check
- In `onHotkeyDown()`, after confirming recording will start: if `settings.audioSettings.pauseMediaDuringRecording` → call `mediaPlaybackController.pauseIfNeeded()`
- In `stopRecordingAndTranscribe()`, right after `audioRecorder.stopRecording()`: call `mediaPlaybackController.resumeIfNeeded()`

Pause point in `onHotkeyDown()` — after the `audioRecorder.startRecording()` succeeds (line ~97):
```swift
if settings.audioSettings.pauseMediaDuringRecording {
    mediaPlaybackController.pauseIfNeeded()
}
```

Resume point in `stopRecordingAndTranscribe()` — right after `recordingIndicator.hide()` (line ~121):
```swift
mediaPlaybackController.resumeIfNeeded()
```

Note: `resumeIfNeeded()` checks `didSendPause` internally, so it's safe to call unconditionally — it only resumes if we actually paused.

## Phase 2: Audio Tab UI

### 2a. Create AudioTabView

**New file**: `vcdr/vcdr/UI/AudioTabView.swift` (~60 lines)

```swift
struct AudioTabView: View {
    let dependencies: AppDependencies

    var body: some View {
        Form {
            Section("Microphone") {
                // Device picker (moved from AudioSectionView)
                // Sound check (moved from AudioSectionView)
            }

            Section("Interaction with OS") {
                Toggle(
                    "Pause media during recording",
                    isOn: /* binding to settings.audioSettings.pauseMediaDuringRecording */
                )
                .help("Automatically pause music and other media while recording, resume when done.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audio")
        .onDisappear { dependencies.inputLevelMonitor.stop() }
        .onChange(of: dependencies.audioDeviceMonitor.selectedDeviceID) {
            if dependencies.inputLevelMonitor.isMonitoring {
                startLevelMonitoring()
            }
        }
    }
}
```

The Microphone section content moves here from `AudioSectionView` — the device picker and sound check. `AudioSectionView.swift` can be deleted or repurposed. The level monitoring lifecycle (`onDisappear`, `onChange`, `startLevelMonitoring()`) moves from `HomeTabView` to `AudioTabView`.

### 2b. Add Audio tab to sidebar

**File**: `vcdr/vcdr/UI/MainWindowView.swift`

Add `.audio` case to `Tab` enum (between `.home` and `.modes`):
```swift
case home
case audio      // NEW
case modes
case transcription
```

With title `"Audio"` and systemImage `"speaker.wave.2"`.

Add the switch case:
```swift
case .audio:
    AudioTabView(dependencies: dependencies)
```

### 2c. Remove Audio section from HomeTabView

**File**: `vcdr/vcdr/UI/HomeTabView.swift`

- Remove the `AudioSectionView(...)` block (lines 51-62)
- Remove `onDisappear` that stops level monitor (line 134-136)
- Remove `onChange` for device ID (lines 137-142)
- Remove `startLevelMonitoring()` helper (lines 145-149)
- Remove `import AVFoundation` if no longer needed (still needed for permission request)

## Verification

### Automated:
- `xcodebuild -scheme vcdr -destination 'platform=macOS' build` succeeds

### Manual:
- Audio tab appears in sidebar between Home and Modes
- Audio tab shows "Microphone" section with device picker and sound check
- Audio tab shows "Interaction with OS" section with "Pause media during recording" toggle (on by default)
- Home tab no longer has an Audio section
- Playing music in Spotify/Apple Music/browser → press push-to-talk → music pauses → release → music resumes
- Toggle off "Pause media during recording" → music does not pause during recording
- Existing modes with `preferredInputDeviceID` still load correctly (backward compat)
