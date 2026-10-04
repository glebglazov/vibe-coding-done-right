# A Shortcut starts and stops a run with two intents, and every start needs the card

"Toggle Recording" is replaced by two App Intents. Start Recording is an `AudioRecordingIntent` and a `LiveActivityIntent`, and it refuses to record without the card on every device. Stop Recording waits for the run to finalize and returns its final text. This amends [ADR-0007](0007-mic-presence-renders-recording-run-progress.md), which let the iPad record without a card.

## Context

On an iPad, a Shortcut start crashed VCDR, and Shortcuts said the app was closed unexpectedly. The device log shows the mechanism:

```
liveactivitiesd: Requester is not targeted by an activity request assertion
liveactivitiesd: Requester is not foreground
vcdr-ios:        Live Activity request failed: visibility
vcdr-ios:        Toggle Recording goes on without a card
AppIntents:      Fatal error: AudioRecordingIntent was performed with an active audio session but without a Live Activity
```

- ActivityKit lets a background app request a Live Activity only while a `LiveActivityIntent` runs. That intent gives the app an activity request assertion. An `AudioRecordingIntent` alone does not.
- After `perform()`, AppIntents checks that an `AudioRecordingIntent` that left audio running started a Live Activity. If it did not, AppIntents stops the process. The check is the same on iPad and iPhone, so ADR-0007's "the iPad records without a card" was false.

The toggle also had one output type for two different results. A start returned an empty string, so "Toggle Recording, then Copy to Clipboard" cleared the clipboard on every start. iOS refuses VCDR's own clipboard write from the background, so the Shortcut's own copy step is the only way the text reaches the clipboard.

## Decision

- **Start Recording** conforms to `AudioRecordingIntent` and `LiveActivityIntent`. If Live Activities are off, it refuses. If ActivityKit refuses the card, it discards the run and refuses. A start while a run is in progress returns without a change.
- **Stop Recording** is an app-only `AppIntent` that returns `String`. A success returns the final text. An Empty Result, a cancellation, a processing failure, and "no run" each throw a refusal, so a Shortcut stops before its copy step and the clipboard keeps its content.
- **Is Recording** is an app-only `AppIntent` that returns `Bool`. It is true while the run is Arming or Capturing, which are the phases in which Stop Recording ends a run. One Shortcut can then use `If Is Recording → Stop Recording → Copy to Clipboard`, `Otherwise → Start Recording` behind one button.
- **No Clipboard Delivery.** iOS refused every clipboard write that VCDR made for a Shortcut run (device log: "the pasteboard did not take the text" three times, "copied" zero times). VCDR no longer tries. The Shortcut's copy step owns the clipboard, and the card's success outcome is Transcribed.
- **No card button for a Shortcut run.** A stop from the card cannot reach the clipboard: iOS refuses VCDR's background write, and no Shortcut is running to copy the text. So while a Shortcut run is Arming or Capturing, the card shows no Cancel or Stop button. Keyboard and app runs keep the button.
- **The card's Stop button** is `StopFromCardIntent`. It stays a `LiveActivityIntent` that the widget compiles, and it never waits for the run.
- Both Shortcut intents live in the app target only. A copy of a Shortcut intent in the widget extension made iOS run it in the extension when VCDR was not running.

## Considered options

- **Keep Toggle with no return value.** Rejected by the user: a Shortcut could not get the text.
- **Keep Toggle and return the text only on stop.** Rejected: a start returns an empty value that a copy step writes to the clipboard.
- **Record on iPad without a card.** Not possible: AppIntents stops the process.

## Consequences

- A one-button trigger is a user-built Shortcut with an If on Is Recording. VCDR does not ship that Shortcut.
- A Shortcut run stopped from the keyboard or in the app gives its text to no Shortcut. The text is only in history.
- A one-step "Record" intent that waits for the card's Stop and then returns the text was considered. It is not built: iOS may stop a long-running intent, and nobody has tested the limit.
- Saved Shortcuts that used Toggle Recording must be rebuilt.
