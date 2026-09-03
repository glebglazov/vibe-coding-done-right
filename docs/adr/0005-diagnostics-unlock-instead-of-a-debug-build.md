# Diagnostics ship in Release, unlocked by a gesture

Bugs are noticed during real use, and real use happens on a TestFlight or App
Store build. Our existing log viewer and launch-history views were compiled out
of exactly those builds by `#if DEBUG`, so the one place the interesting
failures happen was the one place their evidence could not be read — even
though `AppLog` already writes every line into the persistent `LogBuffer` in
Release. We now compile those views into every build and hide them behind a
**Diagnostics Unlock**: ten taps on the **Version Row** (bottom of the Home tab
on macOS, bottom of Settings on iOS), persisted per device in
`UserDefaults.standard`, revealing the Diagnostics tab on macOS and the
Diagnostics section on iOS until the user locks it again. Debug builds are
unlocked implicitly, so nothing changes at the desk.

## The constraint that makes this safe

A **Diagnostics Surface** only ever *reads* material the app already recorded.
Anything that changes app behavior — test-audio injection
(`AudioRecorder.testAudioFileURL`), `DebugTestRunner` — stays behind
`#if DEBUG` and is never one gesture away in a shipped build. This line is what
lets the same binary go to TestFlight and the App Store; if it erodes, the
decision below stops being defensible.

## Considered options

- **A separate build configuration or `.xcconfig` flag.** Rejected: it produces
  two binaries, so the build under test is not the build that ships — which
  defeats the reason for wanting this in TestFlight at all.
- **Runtime detection of a TestFlight install (sandbox receipt).** Rejected: it
  is new machinery to maintain, it cannot tell a TestFlight install from an
  Xcode one reliably, and it gives a real user reporting a bug nothing.
- **A server-side per-device flag.** Genuinely cheap — both apps already call
  `https://vcdr-server.glebglazov.me/v1/prompts` at launch — but rejected for
  now: the unlock would arrive asynchronously and fail when the network does,
  which is precisely the day the logs matter; it would put a device identifier
  and an allowlist on the server, so an App Store build phones home with
  something that identifies the install; and `identifierForVendor` does not
  exist on macOS, so it would need a minted device id displayed in the Version
  Row — which is the gesture option's groundwork anyway. It remains available as
  a strictly additive second door, OR-ed with the gesture, changing nothing
  built here.

## Consequences

- The App Store build carries the Diagnostics Surfaces. That is accepted: they
  are read-only, they display data that never leaves the device unless the user
  shares it, and the gesture is not discoverable by accident.
- The Version Row is now load-bearing rather than decorative — a log is only
  useful against a known build — so it cannot be removed from either app
  without replacing the unlock affordance.
- Keeping recorded audio alongside history, the capability this work was
  originally scoped around, is deferred. It becomes a payload inside
  Diagnostics once the surfaces exist; on macOS it means not deleting the WAV
  that `CaptureSession+Processing` removes today, and on iOS it means teeing
  the `AVAudioEngine` buffers into a file, since iOS writes no audio to disk at
  all.
