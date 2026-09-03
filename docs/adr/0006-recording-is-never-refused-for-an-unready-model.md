# ADR-0006: Recording is never refused for an unready transcription model

## Status

Accepted. Amends decision 3 of [ADR-0002](0002-shell-first-initialization.md).

## Context

ADR-0002 made Backend Rejection unconditional on macOS: any recording attempt
before `transcriptionProvider.isReady` is refused with a buzz and the message
"Not ready". That message is the negation of the state the app wants to be in
rather than the state it is in, so it cannot distinguish a five-second compile
from a failed install — and the app already knows the difference. `InitPhase`
has carried `notStarted / downloading / compiling / ready` since it was written,
and `AppDependencies` already renders those phases into the menu bar and the
Transcription tab. Only the surface the user actually hits — the hotkey — throws
that knowledge away.

The macOS code had already half-abandoned the unconditional rule.
`CaptureSession+Recording.swift` rejects on `!isReady`, then fifteen lines later
comments "Don't gate on model readiness — start audio immediately and let the
model finish loading in the background", and `CaptureSession+Processing.swift`
implements exactly that: a cancellation-aware wait for readiness before
transcribing. The catch-up machinery exists, works, and is unreachable for the
case it was built for. iOS reached the opposite conclusion for the same backend
— a Recording Run may begin before Transcription Readiness, audio buffers, and
Finalizing waits — and iOS never says "not ready".

A middle position was considered and rejected: accept while the model loads
(seconds) and keep refusing while it downloads (minutes), on the grounds that a
minutes-long wait holds a finished recording hostage. The objection cuts the
other way. Refusing destroys the utterance the user was about to speak, and it
does so precisely on the launch where they are most likely meeting the product
for the first time. A narrated wait keeps the recording; a refusal keeps
nothing.

## Decision

Recording is never refused because the transcription model is not ready. The
wait moves to the only moment the app genuinely cannot proceed without the
model, and is narrated there.

1. **The hotkey always starts a recording.** The existing wait in
   `processTranscription` is the mechanism; it stops being an unreachable
   fallback and becomes the designed path.
2. **The wait is narrated with the Model Preparation Phase**, at the point of
   need — "Downloading model", "Loading model" — carrying iOS's existing
   assurance that the recording is safe.
3. **The phase is also shown when recording starts during a download**, not only
   at the end. A user who is told only after speaking learns the cost of the
   wait too late to decide against it.
4. **No surface names the absence.** The rejection path, the menu bar, and the
   settings badge all render the phase. The string "Not ready" leaves the
   product, and with it the buzz that accompanied it.
5. **Progress is elapsed time, not a percentage.** FluidAudio 0.12.1's
   `AsrModels.download` accepts no progress handler and its
   `DownloadUtils.ProgressHandler` is documented "unused but kept for API
   compatibility". The Preparation Heartbeat is the number we can tell the truth
   about. A real percentage would require VCDR to drive the four per-file
   `DownloadUtils.loadModels` calls itself, taking on the library's own cache
   check and recovery — a redesign disproportionate to the copy problem.
6. **The phase vocabulary is shared.** macOS adopts iOS's existing strings
   verbatim and the phase-to-text formatter is hoisted into `Shared/`, because
   `InitPhase` is already duplicated identically in both providers and a second
   copy of the formatter is how the two products' wording drifts apart.

Backend Rejection survives as a Shared concept for backends where refusing is
the honest answer. It no longer applies to the transcription model.

## Consequences

- A recording started before the model is ready now succeeds where it
  previously bounced. The panel's processing wait becomes a path users reach on
  purpose, so its cancellation behaviour is user-facing: cancelling during the
  wait discards the audio, and that has to read as a deliberate choice rather
  than a way out of a hang.
- On a cold download the app can now hold a finished recording for minutes. This
  is accepted deliberately, and it is why decisions 2 and 3 above are both
  required — an unnarrated version of this behaviour would be worse than the
  refusal it replaces.
- `Preparing` and `Downloading model` become distinct labels. Every launch after
  the first stops claiming to download, which is a visible change on the menu
  bar even though nothing about initialization moved.
- Permissions stay a separate subject from model readiness. `HomeTabView`
  already gives microphone and Accessibility their own actionable rows; folding
  them into the preparation label would put two unrelated blockers behind one
  sentence. The hotkey path's `"Failed to start recording"` is fixed in place
  instead, by naming its cause.
