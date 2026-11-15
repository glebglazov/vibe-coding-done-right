---
status: superseded by ADR-0010
---

# Discard is announced after a dwell, not signalled at touch-down

> **Superseded by [ADR-0010](0010-discard-saves-the-run-to-history.md):** Discard is no longer a hold on STOP. STOP is a plain tap, and Discard is a separate ✕ control. A Discard ends the run at once, and a Discard during Capturing saves the run's verbatim transcript to History as a Discarded Conversation instead of deleting it. AI Prompt Mode and Text Style are locked during Arming and Capturing, which reverses this ADR's amendment that kept the pills usable for the whole run.

Holding Stop shows nothing for the first second (the Discard Dwell). Only then does the Discard Warning appear — the surface around Stop reddening over two seconds while haptic ticks accelerate — with Discard firing at a three-second Hold Threshold. The control keeps saying "STOP" throughout, and a reserved row above the controls carries the teaching — the Discard Hint at rest, and live narration of the escape hatch and the deadline once the warning is up.

## Context

Discard was signalled from touch-down: a progress ring on the app's Stop button, a fill sweep on the keyboard's Stop pill, both running the moment a finger landed and completing at a two-second threshold.

Three things were wrong with that.

The signal fired on every stop. A plain tap-to-stop is a touch-down too, so the ring flashed on an interaction that had nothing to do with discarding — the user saw motion they could not explain and had no reason to connect to cancellation.

The signal did not say what it meant. A filling ring communicates "a timer is running", not "this recording is about to be thrown away". Nothing on screen named the outcome, and nothing taught the gesture.

The signal was under the finger. The app's Stop button is 96pt and the keyboard's Stop pill is 32pt tall; a thumb held on either covers most of the animating area. Feedback drawn inside the control is feedback the person performing the gesture cannot see.

Separately, the ring was drawn with a centred stroke on the same 96pt frame as the filled disc, so half its width fell outside the button — it read as a ring floating around Stop rather than part of it.

## Decision

- **Discard Dwell of 1s.** Touch-down starts nothing visible. A hold that ends inside the dwell is an ordinary stop and looks like one.
- **Discard Warning over the following 2s**, revealed with a light haptic tick and a short fade so the transition is felt as well as seen. The warning ramps with elapsed time rather than appearing at full strength.
- **Hold Threshold of 3s** (was 2s). One second of warning is not enough to read and react to; three seconds of hold is not enough to feel stuck.
- **The label stays "STOP".** Releasing performs a stop, so the control names what release does. Discard is carried by colour, haptics, and the Discard Hint — never by relabelling the button mid-gesture.
- **The warning renders around the control, not inside it.** The main app tints its background; the Full Keyboard tints its toolbar strip; the Compact Keyboard fades in a red backdrop across its row for the duration of the hold and drops it on release. The progress indicator survives, inset with `strokeBorder` so it sits inside the button edge, as the only precise "how much longer" cue.
- **Haptic ticks accelerate** across the ramp (light, roughly 350ms to 120ms) with a medium thump at discard, from a retained prepared generator. Keyboard haptics remain subject to the existing user setting; with haptics off the visual ramp stands alone, and no third variant is built.
- **A reserved row above the controls carries the Discard Hint** — "Hold STOP to discard" — in both keyboard states and in the app. Reserved permanently at a shared tunable height sized to the hint, so no layout changes when a run starts or while a hold is in progress. *Amended — see below: the text now shares a line rather than owning one, and the no-layout-change guarantee is kept by the line, not by the row.*
- **That row narrates the hold and doubles as the surface's status line.** *Amended: on the keyboard it narrates the hold only.* It says the resting hint through the whole dwell, then "Release to keep" plus a countdown of the whole seconds left, derived from the controller's own ramp and warning window rather than a second timer. Between holds it carries transient run states (transcribing, no speech detected). Precedence is fixed: hold narration, then a transient status, then the resting hint. Content comes from one shared source (`StatusRowContent`) so the two surfaces cannot diverge, and the narration is hidden from VoiceOver, which already has the direct "Discard recording" action.
- **Releasing mid-warning eases the tint out over ~200ms** rather than snapping, so backing out reads as intentional.
- VoiceOver gets a direct "Discard recording" action; the three-second hold is never the only path.

## Amendment — the status text shares a line instead of owning one

The row was given a line of its own because its widest string ("Hold STOP to discard", ~130pt at 11pt semibold) does not fit beside the keyboard's settings pills, and because a line that appears when a run starts would move the extension's frame at exactly the wrong moment.

The first reason held; the second turned out not to require a separate line at all. On a ~400pt strip the action button and chevron take a third of the width and the settings pills take most of the rest, so the hint now takes the **pills' place** on the control line. The swap happens inside a strip whose height is fixed either way, so a run still starts, ends and is held without the frame moving.

**The pills yield only for the hold itself**, not for the whole run. AI mode and text style are worth changing mid-run — a wrong mode is most obvious while the result is being transcribed — so anything that hid them for the length of a run traded a real control away for a hint nobody needs at that moment.

That means the hint has to arrive on press rather than with the run, and it has to arrive **before** the Discard Warning it explains: `HoldToDiscardController.hintDelay` (0.25s) puts the words up a quarter-second into a hold, well inside the 1s dwell, and they stay until the hold ends by release or by firing. A tap-to-stop is over before the delay elapses, so an ordinary stop still shows nothing — the objection that sank touch-down signalling in the original decision.

- Full Keyboard toolbar: 64pt → **44pt** (`KeyboardDisplayModeManager.fullToolbarHeight` is now just the control strip).
- Compact Keyboard: 80pt → **60pt** (`CompactKeyboardView.intrinsicHeight` is padding plus pill again).
- The app's recording screen keeps an always-available line, on its own terms: the text shares the App Shell's icon line (`RecordingView.header`), which reserves the icons' height whether or not they are rendered. Nothing on that screen competes for the slot, so nothing there is conditional on a hold.
- `KeyboardStripLeading` owns the swap for both keyboard states, so Full and Compact still cannot diverge, and `StatusRowContent` is still the single source of what is said.

What this costs: **the keyboard's slot no longer carries transient statuses.** "Transcribing…" and "No speech detected" were tenants of the reserved row; on the keyboard the action pill already states both (the pulsing orange `…`, and a yellow Start), so the wording is dropped there rather than fighting the pills for the slot. The app's line still carries them in words.

## Considered options

- **Rename the control during the hold** ("STOP" → "DISCARD", `stop.fill` → `trash.fill`). The clearest possible statement of the outcome. Rejected: it lies about release. A user who lets go of a button reading "DISCARD" gets a transcript, and the words that made the warning legible made the escape hatch wrong.
- **Keep the two-second threshold and compress the warning into the last second.** Preserves existing muscle memory and test timings. Rejected: a warning the user can only read after it is over is not a warning.
- **Reserve the hint row only while recording.** Keeps the Compact Keyboard at its current height at rest. Rejected: the height change lands exactly when a run starts, which is the moment the interaction needs to be still.
- **Slide-to-trash** — hold, then drag onto a target. Highest intent clarity available. Rejected: it replaces the hold gesture the Keyboard Channel and ADR-0003's command path are built around.

## Consequences

- ~~**The Compact Keyboard is taller, always.** The reserved row costs roughly a quarter of its 60pt height, paid at idle as well as during recording, and `CompactKeyboardView.intrinsicHeight` is no longer just padding plus pill.~~ Withdrawn by the amendment above: Compact is back to 60pt and `intrinsicHeight` is padding plus pill again. What survives is that the hint is carried outside the control, on a line whose height never changes.
- **Discard takes 50% longer.** Deliberate discards cost a second more, and the threshold lives in two places — `HoldToDiscardController` and the keyboard's own timer in `KeyboardViewController` — both of which move together, as do the controller's tests.
- **Freshness stays coupled to the threshold.** ADR-0003's freshness window is sized against how long a Discard takes to express; a longer hold eats into the margin before a queued cancel goes stale.
- **The warning is a surface concern now**, so each surface owns its own destructive treatment rather than sharing one component. The Compact Keyboard's transient backdrop is a deliberate exception to its see-through-at-rest background.
