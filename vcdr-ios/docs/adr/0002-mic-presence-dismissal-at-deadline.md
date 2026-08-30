---
status: superseded by ADR-0006
---

# Mic Presence is dismissed at the Presence Deadline, not flipped to a stale "idle" rendering

> **Superseded by [ADR-0006](0006-mic-presence-is-a-live-rendering-of-in-place-reachability.md):** Scheduling the activity's own dismissal with `end(_, .after(deadline))` freezes it, so a force-quit, jetsam or suspended teardown leaves it advertising readiness that no longer exists and cannot be withdrawn. Mic Presence is now kept live and refreshed with `staleDate` set to the keyboard's heartbeat freshness window, so iOS flips it to a not-ready rendering autonomously. This trades autonomous dismissal for autonomous honesty.

For a finite Hot-Session Timeout, the Live Activity that backs Mic Presence is **scheduled to dismiss itself at the Presence Deadline** via ActivityKit's `end(_, dismissalPolicy: .after(deadline))`, set when the idle window is armed. It is no longer kept live with a `staleDate` that the system flips to a "Mic idle" rendering at the deadline. This makes the implementation match the documented Mic Presence contract — *"should end around the timeout deadline rather than remain visible as a stale readiness signal"* — at the cost of the warm-idle window being hosted by an **ended-but-still-visible** activity that cannot be updated.

## Context

The Live Activity exists to give the un-suppressible system orange mic indicator an identity ("this is VCDR using your mic"); its lifecycle is tied to the hot audio engine, not the recording flag (`HotMicActivityController`). Under a finite Hot-Session Timeout the engine genuinely runs for the whole window (`AudioRecorder.isHot == audioEngine.isRunning`), so the orange dot is on the entire time and the presence is honest.

The prior implementation mapped the Presence Deadline onto the activity's `staleDate`. At the deadline the system flipped the widget to its stale rendering ("Mic idle") and the app removed the activity later, via `teardown()` → `presence.stop()`. Because the app cannot run code while suspended, the only autonomous signal at the deadline was the stale flip — so a backgrounded/killed app left "Mic idle" visible for the seam between the deadline and the next time the app ran. Users saw a lingering "Mic idle" status they read as pointless.

This directly contradicted the glossary: Mic Presence is defined to *end* at the deadline rather than persist as a stale readiness signal, and Presence Deadline lists "stale date" under _Avoid_. The glossary was right; the code was the deviation.

The constraint that forces the trade-off: there is no ActivityKit API to schedule the *removal* of a still-live activity. Auto-dismissal at a wall-clock instant is available only through `end(_, dismissalPolicy: .after(date))`, and an ended activity can no longer be `update()`d.

## Decision

For a **finite** Hot-Session Timeout:

- On Capturing, `request` a fresh live activity ("Ready to record", no deadline) — updatable while recording.
- On stop, `end(content, dismissalPolicy: .after(presenceDeadline))`. The activity lingers showing "Ready to record" and the system removes it at the deadline with no app code running. There is no stale "Mic idle" state.
- A new recording within the window cannot update the ended activity, so it `request`s a new live one and `end(.immediate)`s the old ended one. The visual replacement blink is accepted as rare and invisible in practice.
- Shortening the timeout while warm (policy change) reschedules the dismissal to the new earlier deadline; `reset()` and Readiness Fail-Closed teardown still `end(.immediate)`.

The `staleDate` mapping and the widget's `isStale` → "Mic idle" branch are removed.

**Always** keeps a live, never-dismissed activity for the app lifetime. **Never** (the default) shows the activity only during an actual recording and `end(.immediate)`s on stop. Both are unchanged; this ADR concerns the finite case only.

## Considered options

- **Keep `staleDate`, accept the "Mic idle" tail** (status quo). Rejected: contradicts the Mic Presence contract and is the exact thing the user objected to.
- **Drop `staleDate`, rely on the in-process idle timer to `end(.immediate)` at the deadline.** Clean while the app is alive, but a suspended/killed app would keep showing "Ready to record" — false readiness VCDR can no longer honor (a Readiness Fail-Closed violation on the visible signal). Rejected because it fails exactly when autonomous behavior matters.
- **`end(.after(deadline))`** (chosen). The only mechanism that removes the activity autonomously while suspended *and* never shows a stale signal. Costs the ended-but-visible warm window and per-recording re-`request`.

## Consequences

- **The ended-activity rendering must be verified on a real device.** Whether iOS renders an *ended-but-not-yet-dismissed* activity at full brightness or dims/demotes it is OS behavior not visible in code. This is the load-bearing assumption: if dimming is acceptable (honest, still auto-removed), ship; if not, revisit. Verify before considering the work done.
- **No glossary change.** This pays down a contradiction; Mic Presence and Presence Deadline already describe the new behavior.
- **The suspended/killed seam is consistent.** When the app is suspended past the deadline the engine is also down (orange dot off), so autonomous dismissal removes the activity without leaving a contradicting indicator.
- **Mic Presence renewal under finite policy becomes near-idempotent.** Scene re-activation that preserves the existing deadline must not try to `update()` the ended activity; the scheduled dismissal already encodes the correct deadline.
- **Regression tests for the Mic Presence timeout contract** must assert dismissal-at-deadline rather than a stale flip.
