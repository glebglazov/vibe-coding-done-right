# Mic Presence is a live, staleness-tracked rendering of In-Place Reachability

Mic Presence is kept **live and periodically refreshed**, with `staleDate` set to the same freshness window the keyboard uses to decide between an in-place Darwin command and a Deep-Link Fallback. When VCDR stops being reachable, iOS flips the activity to a not-ready rendering on its own, with no app code running. This replaces the frozen `end(_, dismissalPolicy: .after(deadline))` activity chosen in [ADR-0002](0002-mic-presence-dismissal-at-deadline.md), trading autonomous *dismissal* for autonomous *honesty*.

## Context

Mic Presence exists to give the un-suppressible system orange mic indicator an identity, and to answer one question for the user: will my next keyboard tap record in place, or bounce me into the app? That question has a name now — **In-Place Reachability** — and exactly one predicate decides it, `KeyboardChannel.isAppLikelyAlive`, an 18-second freshness window over the Heartbeat the app writes every 5 seconds.

ADR-0002 removed `staleDate` and scheduled the activity's own dismissal with `end(content, dismissalPolicy: .after(presenceDeadline))`. That call **freezes** the activity: it stays on screen rendering "Ready to record" and can no longer be updated. For the entire warm idle window the app has therefore already surrendered its ability to correct the thing. If readiness dies before the deadline — force-quit, jetsam, teardown while suspended — the frozen card keeps advertising readiness that no longer exists, and `HotMicActivityController.init`'s sweep only cleans it up at the *next* launch. Live Activities survive app termination by design, so this is the ordinary case, not an exotic one.

Two constraints frame the whole problem:

- `update()` and `end()` are app calls. If the process is gone, neither runs.
- The **only** thing iOS does autonomously to a Live Activity is the `staleDate` flip. It is the sole mechanism that survives force-quit, jetsam and suspension alike.
- Scheduled dismissal (`.after(date)`) and staleness tracking are mutually exclusive, because scheduling dismissal requires ending, and an ended activity tracks nothing.

ADR-0002 was not wrong about `staleDate` as a mechanism. It was wrong about what it pointed the mechanism at: it mapped `staleDate` onto the **Presence Deadline**, a timeout, produced a meaningless "Mic idle" tail, and discarded the tool. Pointed at **liveness** instead, it is the only thing that does the job.

The requirement that forced this was stated plainly: a readiness signal that shows strictly wrong data is worse than no readiness signal at all.

## Decision

Mic Presence renders In-Place Reachability and nothing else.

- The activity is **requested live and kept live**. On every Heartbeat tick the app calls `update()` with `staleDate = now + heartbeatFreshnessWindow` (18s), the same constant the keyboard reads. The card and the keyboard therefore cannot disagree about whether the next tap redirects — they are two renderings of one predicate.
- When the app stops beating, iOS flips the card to its stale rendering with no app code running. That covers force-quit, jetsam and suspension identically.
- `ContentState` gains an `isRecording` flag. Three faces: **Ready**, **Recording**, and the system-driven **stale** face. `staleDate` lives on `ActivityContent`, not `ContentState`, so the honest not-ready face costs no state.
- Presence is **not shown while the app is in the foreground**. It is ended on scene `.active` and requested on the `.background` transition if the session is still warm — the app on screen is a better answer than a card describing it.
- At the Presence Deadline the app, if it is executing, tears down and ends the activity immediately. If it was already suspended, the beat had stopped and the card is already stale. The deadline no longer needs its own mechanism; liveness covers it.
- `HotMicActivityController` is **serialized**: every `start` / `stop` / `update` becomes a command on a single-consumer queue, processed one at a time. Its serialized `stop` also reconciles against `Activity<HotMicActivityAttributes>.activities` and ends strays.

The keyboard renders the same predicate as a glow on its record control, polling `isAppLikelyAlive()` on a ~2s timer while visible. It deliberately does **not** probe more accurately than that.

## Considered options

- **Keep ADR-0002's `end(.after(deadline))`.** Rejected: it is frozen for the whole warm window and lies whenever the app dies early, which is the specific failure the requirement forbids.
- **"Visible if and only if reachable."** The ideal, and **not available from the platform**. The only scheduled-disappearance API is `.after(date)`, which requires freezing first — so insisting on this invariant means deleting the feature.
- **Delete Mic Presence entirely.** A serious option, and the stated fallback had honesty been unreachable. Rejected only because `staleDate`-as-liveness makes honesty reachable.
- **Show presence only during an active recording.** Shrinks the lingering-card window, but deletes the feature's purpose: warm idle is exactly when the user cannot otherwise tell whether a tap will redirect.
- **A wider stale horizon (~60s) to dodge possible update throttling.** Rejected: it breaks the one-predicate rule immediately and widens the false-ready window to a minute.
- **An active Darwin ping from the keyboard for the glow.** Rejected for being *too* accurate — it could glow reachable while `isAppLikelyAlive` reads stale, redirecting the user anyway. A rendering must not be a better oracle than the decision it predicts.

## Consequences

- **Nothing removes a stale card when the app is dead.** It goes honest and then lingers until iOS's own limits (~8h to auto-end, ~12h to clear) or the next launch sweep. Accepted deliberately: a dim honest card beats a bright false one.
- **Three device observations are load-bearing and unverified.** Whether ActivityKit throttles an in-process `update()` at a 5s cadence from the background; how iOS actually renders the stale state; and whether an activity can be requested at the `.background` scene transition (the app declares `UIBackgroundModes = audio, processing`, which should permit it). Verify before considering this done.
- **Throttling fails safe.** If `update()` is throttled, `staleDate` stops advancing and the card goes stale while VCDR is still reachable. It under-promises, never over-promises, so the invariant holds; only usefulness degrades.
- **The duplicate-activity defect is fixed by the serialization, not by this rendering change.** The reentrancy race in `ensureLiveActivity` / `scheduleDismissal` is independent of ADR-0002 and would have survived it.
- **Glossary.** Adds **In-Place Reachability**; amends **Heartbeat** (asserts process reachability, not engine warmth) and **Mic Presence** (a rendering of In-Place Reachability, never a claim it cannot withdraw, absent in the foreground).
- **Tests.** The ADR-0002 regression tests asserting dismissal-at-deadline are replaced by tests asserting the stale horizon tracks the heartbeat window, and that concurrent `start` calls produce exactly one activity.
