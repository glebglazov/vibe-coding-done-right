# Discard queues a freshness-stamped command instead of falling back to a deep link

Discard — the user holding Stop past the hold threshold to end a Recording Run without producing text — is the one Keyboard Channel command that **never uses Deep-Link Fallback**. When the Heartbeat is stale or the command is not acknowledged, the keyboard leaves the cancel command queued with a wall-clock stamp and flips itself to idle immediately; the app applies it when it next runs, and ignores it if it is older than the freshness window. Start and stop keep their existing Deep-Link Fallback.

## Context

Every other Keyboard Channel command treats unreachability the same way: if the Heartbeat is stale, or the app does not acknowledge within ~0.4s, open the app via URL so the user's intent definitely lands (`KeyboardViewController.startRecordingFromKeyboard`, `stopAndWaitForResult`). That is right for start and stop, where the user is waiting on a result — a foregrounded app is a smaller cost than a dropped recording.

Discard inverts the payoff. The user's intent is *"throw this away and leave me alone"*. Yanking them out of the host app and into VCDR to complete a discard delivers the opposite of what they asked for, and the thing being protected is a transcript they have already decided they don't want.

But a queued command is not free. `Command` is a single read-and-clear key in the app group, with no notion of which run it refers to. A cancel written while the app is suspended could be read much later — after the user has started a *new* recording — and would kill the wrong run. That is a worse failure than the app bounce.

## Decision

- Add `cancelRecording` to `KeyboardChannel.Command`, written together with a wall-clock stamp.
- The keyboard sends it, flips to idle, and shows the cancelled flash. It does not wait for acknowledgement and does not open a URL — there is no `vcdr-ios://cancel`.
- The app applies a cancel command only if the stamp is within the freshness window (~10s); an older one is discarded unapplied. A stale Discard is dropped, never redirected onto a later Recording Run.
- Scope is Arming and Capturing. A Discard arriving during Finalizing is ignored — the model load or AI call in flight is not abortable.
- The run terminates in `cancellation`, the terminal state that already exists: no Bundled Result, no Conversation, captures cleared, Hot Mic Session left warm.

## Considered options

- **Deep-Link Fallback, as start and stop do.** Guarantees the run dies now. Rejected: foregrounding the app to discard something is the exact interruption Discard exists to avoid.
- **Queue with no stamp.** Simplest. Rejected: a cancel sitting in the app group across a suspend can be read after a new recording has started and kill it — silent data loss on a run the user wanted.
- **Queue with a freshness stamp** (chosen). No app bounce, and the only cost is that a Discard sent to a long-suspended app may not apply — acceptable, because a suspended app is not recording.

## Amendment (2026-11-27): Keyboard Channel v2

The single read-and-clear command slot and its separate stamp key are gone. The keyboard now appends each command, with its own ID and its `sentAt` time, to a list that only it writes. A Discard also names the run the keyboard showed.

- The freshness rule is unchanged: the app drops a Discard whose `sentAt` is older than the window (10 s, `KeyboardChannel.discardFreshnessWindow`).
- The app also drops a Discard whose run is not the current run. So a queued Discard cannot reach a later run even inside the window.
- The queue keeps every command in order. A Discard followed by a stop are both taken; the stop then finds its run ended and does nothing, so the discarded text is not delivered.

## Consequences

- **A Discard can be a no-op without telling the user.** The keyboard shows the cancelled flash optimistically. If the app was suspended past the freshness window, the run it would have cancelled is already over by other means; if it somehow is not, the recording continues. Accepted deliberately — the alternative is blocking the keyboard on an acknowledgement it usually cannot get.
- **The freshness window is a real tuning knob**, not an implementation detail. Too long and a stale Discard reaches a fresh run; too short and legitimate Discards are dropped while the app takes its time waking.
- **Discard is not symmetric with stop**, and future work that unifies the command paths must keep the asymmetry deliberate rather than "fixing" it.
