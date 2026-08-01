# Discard is announced after a dwell, not signalled at touch-down

Holding Stop shows nothing for the first second (the Discard Dwell). Only then does the Discard Warning appear — the surface around Stop reddening over two seconds while haptic ticks accelerate — with Discard firing at a three-second Hold Threshold. The control keeps saying "STOP" throughout, and a stationary Discard Hint above the controls carries the teaching.

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
- **A reserved row above the controls carries the Discard Hint** — "Hold STOP to discard" — in both keyboard states and in the app. Reserved permanently at a shared tunable height sized to the hint, so no layout changes when a run starts or while a hold is in progress.
- **Releasing mid-warning eases the tint out over ~200ms** rather than snapping, so backing out reads as intentional.
- VoiceOver gets a direct "Discard recording" action; the three-second hold is never the only path.

## Considered options

- **Rename the control during the hold** ("STOP" → "DISCARD", `stop.fill` → `trash.fill`). The clearest possible statement of the outcome. Rejected: it lies about release. A user who lets go of a button reading "DISCARD" gets a transcript, and the words that made the warning legible made the escape hatch wrong.
- **Keep the two-second threshold and compress the warning into the last second.** Preserves existing muscle memory and test timings. Rejected: a warning the user can only read after it is over is not a warning.
- **Reserve the hint row only while recording.** Keeps the Compact Keyboard at its current height at rest. Rejected: the height change lands exactly when a run starts, which is the moment the interaction needs to be still.
- **Slide-to-trash** — hold, then drag onto a target. Highest intent clarity available. Rejected: it replaces the hold gesture the Keyboard Channel and ADR-0003's command path are built around.

## Consequences

- **The Compact Keyboard is taller, always.** The reserved row costs roughly a quarter of its 60pt height, paid at idle as well as during recording, and `CompactKeyboardView.intrinsicHeight` is no longer just padding plus pill. This directly amends what "as little screen as a dictation surface needs" means for that state. The row is currently empty outside recording; giving it a second job at rest is open work.
- **Discard takes 50% longer.** Deliberate discards cost a second more, and the threshold lives in two places — `HoldToDiscardController` and the keyboard's own timer in `KeyboardViewController` — both of which move together, as do the controller's tests.
- **Freshness stays coupled to the threshold.** ADR-0003's freshness window is sized against how long a Discard takes to express; a longer hold eats into the margin before a queued cancel goes stale.
- **The warning is a surface concern now**, so each surface owns its own destructive treatment rather than sharing one component. The Compact Keyboard's transient backdrop is a deliberate exception to its see-through-at-rest background.
