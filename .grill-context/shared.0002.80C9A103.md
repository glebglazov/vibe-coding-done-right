---
fragment: 80C9A103
generation: 0002
branch: master
---

~ Backend Rejection
  Refusing a user action because a backend it needs is not ready yet, with immediate visual feedback rather than accepting the action and blocking later. It does not apply to the transcription model: dictation is never refused for an unready model, because refusing destroys the utterance the user was about to speak. Where a backend is not ready and the action is accepted anyway, the wait is narrated at the point of need — never reported as an absence of readiness.
  was: When the user attempts an action that requires a backend that is not yet ready, the shell must reject the action with immediate visual feedback rather than accepting the action and blocking later.
  avoid: not ready, queueing, pending state, silent hang
  under: Initialization

+ Narrated Wait
  Accepting an action that needs a backend which is not ready, and telling the user what the app is waiting on at the moment it actually waits. A Narrated Wait names the Model Preparation Phase, carries a Preparation Heartbeat, and states that work already done is safe. It is announced when the action starts, not only when the wait begins, so the user can judge the cost before committing to it.
  avoid: blocking, hang, spinner, silent queue
  under: Initialization

+ Model Preparation Phase
  The phase of transcription-model initialization that every readiness surface renders: Preparing (init has not begun), Downloading model (artifacts are being fetched), Loading model (artifacts are on disk and being compiled and loaded), Ready, or Failed. It is one vocabulary across macOS and iOS, rendered from one formatter, so the two products cannot word the same wait differently. Preparing and Downloading model are distinct — a launch whose artifacts are already cached never downloads, and must not claim to.
  avoid: init phase label, loading state, not-ready state
  under: Initialization

+ Preparation Heartbeat
  The elapsed-time suffix a Model Preparation Phase label gains once it has lasted past a reveal threshold, so a wait with no measurable progress still reads as bounded and moving. It is what stands in for a percentage: the transcription backend reports no download progress, so elapsed time is the only honest number available.
  avoid: progress bar, percentage, spinner
  under: Initialization

+ Preparation Failure
  A Model Preparation Phase that will not clear by waiting. It is a phase in its own right, not an error string smuggled into a status label, and it carries the action that clears it — reconnect, or retry. Only causes the app can actually distinguish are named; the transcription backend's error text is opaque and is never paraphrased into a cause.
  avoid: Error, Failed: <message>, init error
  under: Initialization
