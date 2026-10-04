# Mic Presence renders Recording Run progress, and one card owns its truth

> **Amended by [ADR-0008](0008-shortcut-start-and-stop-are-separate-intents.md):** "Toggle Recording" is replaced by Start Recording and Stop Recording. A Shortcut start needs the card on every device, iPad included. Clipboard Delivery is removed, so the success outcome is `transcribed`, not `copied`.

Mic Presence now renders the progress of the active Recording Run as well as In-Place Reachability: Arming, Capturing with a running timer, Finalizing, and for a Shortcut run a short outcome. A new `MicPresenceCard` is the card's single writer. It merges three facts, each with its own writer, and it renews the card's `staleDate` itself. The Hot Mic Session only reports reachability. This amends [ADR-0006](0006-mic-presence-is-a-live-rendering-of-in-place-reachability.md), which kept the card a rendering of reachability alone and let the Heartbeat renew it.

## Context

The "Toggle Recording" App Intent is an `AudioRecordingIntent`. It records while VCDR stays in the background, and the system stops that recording unless the app shows a Live Activity for its whole length. A Shortcut run also has no surface of its own: nothing else tells the user that it is capturing, that it is transcribing, or that the text is now on the clipboard. The card is the only place those facts can go, and the user decided against a second card.

ADR-0006's card could not carry them:

- It had two faces, ready and recording, and HotMicSession chose between them. A Shortcut run can start from a cold engine, and under the Never timeout the Hot Mic Session is torn down while Finalizing is still running. The owner of the card was gone exactly when the card had the most to say.
- The Heartbeat renewed the card. With no Heartbeat there was no renewal, so a Finalizing face on a cold engine would go stale after 18 seconds while VCDR was still working.
- The rule "no card while VCDR is in the foreground" would end the Live Activity that an `AudioRecordingIntent` needs whenever the user opens VCDR, or uses iPad Split View, during a Shortcut run.

## Decision

- **One wire state, one face.** `ContentState` is `MicPresenceCardState`: `ready`, `arming`, `capturing(since:)`, `finalizing`, or `concluded(copied | noSpeech | failed)`. A combination such as "recording and copied" cannot be written. Not-ready is still not a case: it comes from `staleDate`, as ADR-0006 decided.
- **Three facts, three writers, one merge.** HotMicSession writes reachability, and it does so inside `startHeartbeat()` and `stopHeartbeat()`, so the card and the keyboard change their minds in the same call. The scene hooks write whether VCDR is in the foreground. The coordinator writes the run, as the active phase or a concluded outcome with its own deadline. `MicPresenceCardPolicy.decide` is pure and turns the three facts into `hidden`, `live(face)`, or `concluding(face, dismissAt:)`. Nobody writes another writer's fact, and no one clears the outcome: the policy stops counting it once its deadline passes, and the card only re-renders at that moment.
- **The card renews itself.** `MicPresenceCard` re-stamps `staleDate = now + heartbeatFreshnessWindow` every 5 seconds while any live face shows. The horizon is unchanged, so the honesty argument of ADR-0006 still holds. Only the owner of the loop moved.
- **An outcome may be frozen.** When no warm session will keep renewing the card, a concluded face is ended with `.after(dismissAt)` and no `staleDate`. ADR-0006 rejected a frozen readiness claim, because readiness can become false. "Copied" cannot.
- **One foreground exception.** A Shortcut run that is Arming or Capturing keeps its card while VCDR is on screen. Every other face follows ADR-0006 and is absent in the foreground.
- **The controller renders.** `HotMicActivityController` drops `start` / `refresh` / `stop` for one serialized `render(decision)`. The serialization and the stray sweep stay as ADR-0006 decided.

## Considered options

- **Let HotMicSession own run progress.** Its `isCapturing` flag would grow into a phase. Rejected: the session would have to learn the Recording Run and outlive its own teardown under the Never timeout, and HotMicSession is scoped to the warm-microphone lifecycle.
- **A second Live Activity for Shortcut runs.** Rejected by the user: two cards describing one microphone.
- **Let the card clear its own outcome after the dwell.** Rejected: the card and the coordinator would both write the run slot, and a new run starting during the dwell would race the clear.
- **Keep the card hidden in the foreground for Shortcut runs too.** Rejected: the system would stop the recording.

## Consequences

- **Finalizing on a cold engine stays honest.** The card renews while VCDR is executing. Finalizing holds a background task, and if that task expires the renewals stop and the card goes stale, which is the truth.
- **A stale card offers no Stop button.** The app behind it is not running.
- **A card from an older build may not decode.** Its `ContentState` was `{ isRecording }`. The launch sweep ends it, as it ends every stray.
- **Unverified on device.** Whether an iPad presents the card, whether the iPad keeps a background `AudioRecordingIntent` recording without one, and whether ActivityKit accepts a request from a scene-less intent launch. On iPad, VCDR records without a card and logs it; on iPhone it refuses the start.
- **Glossary.** Adds **In-Place Reachability**, **Run Origin** and **Clipboard Delivery**, and amends **Mic Presence** and **Hot Mic Session**.
