# Audio-engine warmup preempts the transcription-model compile on record intent

When the user signals intent to record while the on-device transcription model is still specializing, the audio-engine warmup runs at elevated priority and the in-flight model compile is **demoted**, so the microphone arms in ~hundreds of ms instead of seconds. We deliberately make the transcription model *slower to become ready* in order to make the mic feel instant.

## Context

This extends the responsiveness-first tenet (`docs/architecture/rules.md`, Rule 11) and builds directly on ADR-0002 (shell-first) and ADR-0003 (blocking work off the cooperative pool).

On a cold launch the Parakeet encoder ANE specialization (`COLD_SPECIALIZE`) runs 38–45s and starts automatically ~500ms after launch. Device traces showed that a record tap landing *mid-compile* took **~9s just to start the audio engine** — `AVAudioEngine()` construction and `inputNode.outputFormat(forBus:)` (audio HAL / mediaserverd calls) were starved by the concurrent compile. The user saw a dead-looking "recording" with no waveform, gave up, stopped, and got an Empty Result ("no speech detected") because no audio had been captured yet.

A Recording Run now begins at the tap and moves through **Arming → Capturing → Finalizing** (see `vcdr-ios/CONTEXT.md`). Arming — the audio engine warming — must be short for the facade to stay honest, because the UI shows no timer or waveform until Capturing. If Arming takes 9s, the user stares at "STARTING…" for 9s.

## Decision

On record intent, warm the audio engine at `.userInitiated` and demote the model compile's QoS until the engine is hot; resume the compile at its normal background priority afterward. The model finishing a few seconds later on an already-44s compile is invisible; the mic arming in hundreds of ms instead of 9s is not. Audio-engine warmup, like every other blocking syscall, runs off the cooperative pool via `withBlockingTask` (ADR-0003) — this also fixes the fresh-engine path in `AudioRecorder.startEngine`, which was constructing the engine on the cooperative pool in violation of ADR-0003.

## Considered options

- **Pure parallel, no preemption** (just fix the ADR-0003 violation). Rejected as insufficient on its own: the 9s block was CPU/HAL contention from the compile, which equal-priority parallelism does not relieve. Kept as the *fallback* if measurement shows preemption is enough — see Consequences.
- **Eager engine pre-warm at launch**, before any tap. Rejected: warming the mic before intent lights Mic Presence (the system mic indicator) without the user recording — a privacy/UX regression — and fights shell-first by spinning audio during launch. Held in reserve only if preemption proves inadequate on device.
- **The intent-latch (handoff "option a")**: defer recording during cold init, auto-start within a warm window else require a fresh tap. Rejected: it contradicts the documented **Transcription Readiness** model (audio is captured immediately; transcription catches up) and adds a stale-intent state machine to solve a problem that prioritizing the engine solves more simply.

## Consequences

- The priority inversion is surprising: a future reader seeing the compile demoted on record intent would assume it a bug and "fix" it. It is deliberate. Don't.
- Preemption's effectiveness is **not yet measured on device**. An in-flight `MLModel(contentsOf:)` ANE load cannot be paused, only deprioritized; if residual contention is hardware/thermal rather than CPU, Arming may stay long. The fallback ladder is: (1) this preemption, (2) eager pre-warm at launch despite the Mic Presence cost, (3) a real Arming state on the Keyboard Channel so the keyboard surface stays honest under a long Arming. Measure Arming time on a true `COLD_SPECIALIZE` launch before climbing the ladder.
