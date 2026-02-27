---
date: 2026-02-27T08:17:58Z
researcher: Gleb Glazov
git_commit: 0f8e468
branch: main
repository: vibe-coding-done-right
topic: "How does automatic media pause work, and what are alternatives to the current implementation?"
tags: [research, codebase, media-playback, CoreAudio, CGEvent, AppleScript, MediaRemote]
status: complete
last_updated: 2026-02-27
last_updated_by: Gleb Glazov
---

# Research: Media Pause Implementation & Alternatives

**Date**: 2026-02-27T08:17:58Z
**Researcher**: Gleb Glazov
**Git Commit**: 0f8e468
**Branch**: main
**Repository**: vibe-coding-done-right

## Research Question

How does the automatic media pause feature work? It sometimes opens Apple Music or randomly starts music. What alternatives exist to the current implementation?

## Summary

The current implementation simulates the system play/pause media key (`NX_KEYTYPE_PLAY = 16`) via CGEvent. This is a **toggle** — the same event pauses and resumes. A CoreAudio snapshot (`kAudioDevicePropertyDeviceIsRunningSomewhere`) is taken before recording to detect if audio was active, but this check has known false-positive issues (AVAudioRecorder can activate the output device). The fundamental problem: there is no way to send an explicit "pause" (not toggle) via CGEvent — if the detection fails, the toggle can accidentally **start** playback, which is why Apple Music sometimes opens.

Three viable alternatives exist: (1) AppleScript with state checks — most reliable, covers Spotify + Apple Music, prevents launches with `is running` guard; (2) MediaRemote via Perl adapter — works on macOS 15.4+ via a workaround, supports explicit pause command (not toggle); (3) CoreAudio muting — silences output but doesn't actually pause players.

## Detailed Findings

### Current Implementation

#### `MediaPlaybackController` (`vcdr/Audio/MediaPlaybackController.swift`)

A `@MainActor final class` with 109 lines implementing three responsibilities:

**1. CoreAudio output detection** (lines 53-84):
- Queries `kAudioHardwarePropertyDefaultOutputDevice` to get the default output device
- Queries `kAudioDevicePropertyDeviceIsRunningSomewhere` on that device — returns non-zero if any process is sending audio
- Called via `snapshotAudioState()` (lines 20-23) which stores the result in `audioWasActive`

**2. Pause/resume logic** (lines 31-47):
- `pauseIfNeeded()`: guards on `audioWasActive`, sets `didPauseMedia = true`, sends media key
- `resumeIfNeeded()`: guards on `didPauseMedia`, resets flag, sends media key
- The `audioWasActive` guard prevents accidental playback start when nothing was playing

**3. Media key simulation** (lines 89-108):
- `sendMediaKeyEvent()` posts key-down (`0xA00`) and key-up (`0xB00`) events
- Uses `NSEvent.otherEvent(with: .systemDefined, subtype: 8, ...)` posted via `CGEvent.post(tap: .cghidEventTap)`
- This is the same mechanism as pressing the physical play/pause key on a keyboard

#### Integration in `RecordingCoordinator` (`vcdr/Orchestration/RecordingCoordinator.swift`)

The media controller is called at 6 points in the recording lifecycle:

| Location | When | Delay |
|---|---|---|
| `onHotkeyDown()` line 133-135 | Before recording starts | None (snapshot + pause) |
| `onHotkeyDown()` line 154 | Recording start failure | None |
| `stopRecordingAndTranscribe()` line 171 | Guard failure (not recording) | None |
| `stopRecordingAndTranscribe()` line 186 | No audio captured | None |
| `stopRecordingAndTranscribe()` lines 201-203 | Normal stop | 300ms (`audioSettleDelayBeforeResume`) |
| `cancelRecording()` line 334 | Esc cancel | None |

Critical ordering: `snapshotAudioState()` is called **before** `audioRecorder.startRecording()` (line 138) because starting the recorder activates the output device, which causes `kAudioDevicePropertyDeviceIsRunningSomewhere` to return a false positive.

#### Settings (`vcdr/Core/Settings/AppSettings.swift:10-16`)

```swift
struct AudioSettings: Codable, Equatable {
    var pauseMediaDuringRecording: Bool  // default: true
}
```

Toggle in `AudioTabView.swift:47-54`.

### Why It Sometimes Opens Apple Music

The toggle-based approach has an inherent race condition / detection gap:

1. `kAudioDevicePropertyDeviceIsRunningSomewhere` can return false negatives (audio is playing but output device appears inactive — e.g., Bluetooth audio, AirPlay, or audio routing edge cases)
2. If the snapshot incorrectly records `audioWasActive = true` when nothing was actually playing, the pause key **starts** playback instead
3. macOS automatically launches Apple Music when the play/pause key is pressed and no other media app is active — this is system-level behavior VCDR cannot prevent with the current approach

### Alternative 1: AppleScript with State Checks

**How it works**: Run AppleScript to check `player state` before issuing explicit `pause` or `play` commands to specific apps.

```applescript
-- Apple Music (only if already running — won't launch it)
if application "Music" is running then
    tell application "Music"
        if player state is playing then pause
    end tell
end if

-- Spotify
if application "Spotify" is running then
    tell application "Spotify"
        if player state is playing then pause
    end tell
end if
```

**Key advantage**: The `is running` guard prevents launching apps. The `player state is playing` check means you never accidentally start playback.

**Browser media (Chrome/Safari)** can be paused via JavaScript injection:
```applescript
tell application "Google Chrome"
    execute front window's active tab javascript
        "var v = document.querySelector('video'); if (v && !v.paused) v.pause();"
end tell
```

| Aspect | Details |
|---|---|
| Coverage | Apple Music, Spotify, VLC, Chrome, Safari |
| Can check state before acting | Yes (`player state`, `v.paused`) |
| Prevents app launch | Yes (`is running` guard) |
| Entitlements needed | `NSAppleEventsUsageDescription` in Info.plist, "Apple Events" Hardened Runtime capability |
| User prompt | One-time Automation permission per target app |
| Latency | ~50-200ms per app (run concurrently) |
| Firefox support | No (no AppleScript JS injection) |

**Reference implementation**: [BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic) (~18K stars) uses this exact pattern via `BGMAutoPauseMusic.mm`.

### Alternative 2: MediaRemote via Perl Adapter

**How it works**: MediaRemote.framework is Apple's private framework for reading now-playing state and sending explicit play/pause commands. Blocked for third-party apps since macOS 15.4 (requires `com.apple.mediaremote.nowplaying` entitlement). However, `/usr/bin/perl` has a `com.apple.perl5` bundle ID, which passes the entitlement check.

The [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) project bundles a Perl script + framework and invokes it via `/usr/bin/perl`:
- `get` — returns now-playing info including `playing: true/false`
- `send 1` — explicit **Pause** command (not toggle)
- `send 0` — explicit **Play** command

| Aspect | Details |
|---|---|
| Coverage | Any app with now-playing registration (universal) |
| Can check state before acting | Yes (`get` returns playing state) |
| Prevents app launch | Yes (only controls active now-playing source) |
| Entitlements needed | None in your app |
| User prompt | None |
| Latency | Process spawn overhead (~100ms) |
| Future-proofing | Relies on Apple not revoking perl5's entitlement |

### Alternative 3: CoreAudio System Mute

**How it works**: Set `kAudioDevicePropertyMute` on the default output device.

| Aspect | Details |
|---|---|
| Coverage | All audio output (universal) |
| Actually pauses playback | No — silences output, player keeps running |
| Prevents app launch | N/A (doesn't interact with players) |
| User experience | Poor — loses track position, wastes CPU |

**Verdict**: Wrong tool for this problem. Muting doesn't pause.

### Non-Viable Approaches

- **MPNowPlayingInfoCenter / MPRemoteCommandCenter**: Write-only (sets your own app's state). Cannot read or control other apps.
- **MusicKit**: Controls Apple Music only within your own app context. Cannot send commands to a running Music.app.
- **Direct MediaRemote.framework linking**: Blocked on macOS 15.4+ without Apple-internal entitlement.
- **AVAudioSession.duckOthers**: Lowers volume, doesn't pause. For mixing scenarios only.

## Code References

- `vcdr/Audio/MediaPlaybackController.swift` — Full media pause/resume implementation (109 lines)
- `vcdr/Orchestration/RecordingCoordinator.swift:133-135` — Pause integration point (on recording start)
- `vcdr/Orchestration/RecordingCoordinator.swift:201-203` — Resume integration point (on recording stop, 300ms delay)
- `vcdr/Orchestration/RecordingCoordinator.swift:334` — Resume on Esc cancel
- `vcdr/Core/Settings/AppSettings.swift:10-16` — `AudioSettings` struct with `pauseMediaDuringRecording` flag
- `vcdr/UI/AudioTabView.swift:47-54` — Settings toggle UI
- `vcdr/App/AppDependencies.swift:34` — `MediaPlaybackController` instantiation

## Historical Context (from thoughts/)

- `thoughts/shared/plans/2026-02-20-pause-media-and-audio-tab.md` — Original implementation plan. Explicitly chose CGEvent toggle over AppleScript ("requires Automation permission prompt") and MediaRemote ("broken for third parties since macOS 15.4"). The plan noted "No public macOS API to detect if media is playing — CGEvent is toggle-only."
- `thoughts/shared/research/2026-02-21-dictate-transcribe-process-act-risks.md` — Architectural risk analysis referencing `MediaPlaybackController` as a dependency
- MEMORY.md notes: "CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` false positives: AVAudioRecorder starting can activate the output device" and "MediaRemote private framework is blocked on this system (macOS 15.4+)"

## Comparison Matrix

| Approach | Explicit Pause (not toggle) | Prevents App Launch | Coverage | Permissions | Complexity |
|---|---|---|---|---|---|
| **Current (CGEvent)** | No | No | Universal | Accessibility only | Low |
| **AppleScript** | Yes | Yes (`is running`) | Spotify, Music, VLC, Chrome, Safari | Automation prompt per app | Medium |
| **MediaRemote Perl adapter** | Yes (`send 1`) | Yes | Universal | None | High (bundled Perl + framework) |
| **CoreAudio mute** | N/A (doesn't pause) | N/A | All audio | None | Low |

## External References

- [BackgroundMusic — GitHub](https://github.com/kyleneideck/BackgroundMusic) — Reference implementation for multi-player AppleScript pause
- [mediaremote-adapter — GitHub](https://github.com/ungive/mediaremote-adapter) — Perl-based MediaRemote workaround for macOS 15.4+
- [Spotify AppleScript gist](https://gist.github.com/ellcom/58f47d7eeb3601734ef9)
- [Multi-player pause AppleScript gist](https://gist.github.com/mjquinn21/953738cac970871db014ce6303aded2f)
- [Apple Music ScriptingBridge broken in macOS Tahoe 26 — Developer Forums](https://developer.apple.com/forums/thread/801357)

## Open Questions

- Would the one-time Automation permission prompts (per target app) be acceptable UX for the AppleScript approach?
- Should VCDR support a layered strategy (AppleScript for known apps + CGEvent fallback for unknown apps)?
- Is the mediaremote-adapter Perl workaround too fragile to depend on for a shipped app?
- Should browser media pause be supported, or is Spotify + Apple Music sufficient?
