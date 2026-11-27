# The keyboard renders only wire-published terminal states

A Recording Run has four terminal states. The Keyboard Channel now carries all four distinctly — `.failed` carries the app's reason string, `.cancelled` is its own case — and the keyboard renders exactly what the wire says. It no longer infers a terminal state from `.idle`, and no longer synthesizes one locally on Discard.

## Context

`vcdr-ios/CONTEXT.md` has always said a Recording Run terminates in exactly one of success, Empty Result, cancellation, or Processing Failure, and that Empty Result "is distinct from cancellation and processing failure". The wire never carried that distinction. `KeyboardChannel.RecordingState` had four cases that did not correspond to the four terminal states, and `KeyboardChannelRecordingRunCompletionAdapter` collapsed cancellation, every Processing Failure, and success-not-delivered-to-keyboard all onto `.idle`.

Downstream of that collapse, `KeyboardViewController.stopAndWaitForResult` mapped any `.idle` observed during its stop poll to `.emptyResult` — the yellow "no speech" flash. So a mic seizure, a model-load throw, a finalization throw, and a cancelled run all rendered as *"we heard nothing"*. The passive refresh path did not do this; it mapped `.idle` to blue idle. Yellow therefore meant different things depending on whether the user happened to still be inside the blocking poll.

The cost was not merely a wrong colour. It made the yellow state untraceable to a cause **by construction**: a user reporting "it turned yellow" could be reporting any of six unrelated faults, and no log distinguished them, because the extension logs nothing at all. A field report of a genuine Empty Result and a field report of a crashed transcription were the same report.

Discard had the mirror-image problem from the other direction. Because the wire could not express cancellation, the keyboard synthesized its own gray cancelled flash locally — a second source of truth for a fact the app owned.

## Decision

- Widen `KeyboardChannel.RecordingState` so all four Recording Run terminal states are distinct on the wire. `.failed` carries the app's reason string, reusing the `"idle|<text>"` prefix encoding already used for the Bundled Result.
- The stop poll maps `.idle` to blue idle, matching the passive refresh. **Yellow means Empty Result and nothing else.**
- Processing Failure renders as a red FAILED pill. The pill is tappable and deep-links into the main app, where the full reason is already shown by `applyTerminalStateToUI`. The keyboard shows that a failure happened; the app shows what it was.
- Drop the keyboard's locally synthesized cancelled flash. Cancellation is rendered from the wire like every other terminal state.
- Every terminal branch logs its reason before publishing. A Processing Failure that reaches the user must also reach the log.

## Considered options

- **Bare `.failed` with no payload.** Smaller wire change. Rejected: the app already composes precise, user-meaningful messages ("Transcription unavailable: …", "Failed to start recording — check microphone permission"), and discarding them at the process boundary is the substance of the complaint, not an implementation shortcut.
- **Show the full reason in the keyboard.** Rejected: the action button is a pill, and the toolbar strip is already carrying the AI-mode and capture pills. A truncated error is barely better than a colour.
- **Persist failures durably to history.** Rejected for now: a failed run has no transcript, so the entry would be an empty row whose only content is an error string. The in-memory `state = .error(message)` survives backgrounding until the next run overwrites it, which covers the "go back and look" case. Revisit if reasons are routinely lost to a retry.
- **Distinct wire states plus wire-only rendering** (chosen).

## Amendment (2026-11-27): Keyboard Channel v2

The decision stands; the encoding changed. The state key with its `"idle|<text>"` and `"failed|<reason>"` tokens is replaced by one JSON snapshot that only the app writes: the newest run's ID, its phase (`recording`, `transcribing`, `idle`, or `ended` with the outcome), and the IDs of the commands the app took.

- The keyboard no longer consumes a terminal state by writing idle over it. It keeps a record of the run whose outcome it already showed or inserted, so a second read cannot cut a pill and a later appearance does not show it again.
- A pill stays for its flash unless the snapshot shows another run. A new run replaces it at once.
- The keyboard still infers nothing: every terminal state it shows is the one the app published for that run.

## Consequences

- **`SharedConstants.swift` is duplicated across the app and keyboard targets and has already drifted.** The wire types no longer live there: since Keyboard Channel v2 they are one copy in `vcdr-ios/Shared`, compiled into both targets.
- **A failure the user does not tap is a failure they see only as a colour.** Accepted: the alternative is a keyboard that tries to be an error console.
- **The keyboard becomes a pure renderer of app-owned state.** Any future keyboard-side inference about what a run did is a regression of this decision, not a shortcut.
- **Yellow becomes diagnostically meaningful.** A future report of a yellow flash is now a report of exactly one condition, which is what makes the Empty Result instrumentation worth reading.
