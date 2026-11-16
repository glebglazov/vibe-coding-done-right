# Discard is a separate control, and it saves the run to History

STOP is a tap that stops and transcribes. Nothing else. Discard has its own control: a ✕ DISCARD circle to the left of STOP in the app, and a round ✕ pill at the leading end of the keyboard strip. A Discard ends the run at once and never blocks the next run. A Discard during Capturing does not delete the words. The app transcribes the run verbatim on the device and saves it to History as a Discarded Conversation, which the user can process with AI later. There is no Undo. AI Prompt Mode and Text Style are locked while the run is Arming or Capturing. This supersedes [ADR-0004](0004-discard-is-announced-after-a-dwell.md).

> **Amended by [ADR-0011](0011-ios-has-two-ai-prompt-modes-ai-off-and-ai-on.md):** iOS has no Assistant mode and no Captures now. A Discard saves the verbatim text only, Process with AI chooses a style only, and the labels say "AI" and "AI off".

## Context

ADR-0004 put Discard on STOP as a 3-second hold, with a dwell, a red warning, haptic ticks and a status row that taught the gesture. That design had three costs:

- STOP had two meanings. Every stop was a touch-down that could become a discard, so the control needed a warning, a countdown and a hint to explain itself.
- The hint ("Hold STOP to discard") and the narration ("Release to keep · 2s") took the place of the settings pills on the keyboard, and took the status row in the app.
- A discard was final. A user who discarded by mistake lost the recording.

A first version of this ADR answered the third cost with a 5-second Undo Window. During the window the discarded run stayed the active run, so the user could not start a new run, and a user who missed the window still lost the words. The user rejected both results: a Discard must never lose the words for good, and must never block the next dictation.

## Decision

- **STOP is a plain tap.** It stops and transcribes during Capturing, and cancels during Arming, as before. No hold gesture exists.
- **A separate Discard control.** The app shows a 56 pt ✕ circle labeled DISCARD to the left of STOP, with the two circle centres on one line. The keyboard shows a 32 pt round ✕ at the leading end of the strip, away from STOP. VoiceOver reads it as "Discard recording".
- **STOP sits 112 pt above the bottom safe area** in every run, keyboard start or app start, clear of the bottom-edge swipe hint.
- **A Discard ends the run at once.** The run leaves the active-run slot immediately. The app goes to Ready, and the keyboard gets `cancelled`, a terminal state. The user can start a new run at once. A run that the keyboard did not start publishes `idle`, as every other ending of such a run does.
- **A Discard during Arming saves nothing.** No audio exists. The app shows no CANCELLED page.
- **A Discard during Capturing saves the run to History.** Capture ends. A `DiscardedRunFinalizer` takes the run in a background task. It gets the verbatim text from the run's streaming session: the raw transcript, with no Substitutions, no filler removal and no AI. If the text is not empty, it calls `HistoryStore.recordDiscarded` with the text and the Recorded Output Choice. The Conversation format is in shared [ADR-0028](../../../docs/adr/0028-a-conversation-has-a-status.md).
- **One decode at a time.** A new run starts capture at once, but its transcription setup waits for any discarded run that is still finalizing, the same way a run already waits for the model. A run must buffer its audio until setup completes.
- **The app note tells the truth.** When the finalizer reports, the app shows "Discarded · saved to History" with VIEW, which opens History on that entry. When nothing was saved (Arming, or no speech), it shows "Discarded". The note never says "saved" before the save happened. It shows for 3 s and goes on a RECORD tap. If a new run started before the finalizer reported, the app shows no note: the new run owns the screen, and the entry is in History.
- **The keyboard shows a grey "✕ DISCARDED" pill** for about 1 s, in place of the CANCELLED pill, then START. A tap on the pill starts a run, as START does.
- **Process with AI is in History.** A tap on a discarded row opens a sheet: Process with AI (with the recorded style, or another style), Copy raw text, and Delete. Processing runs the full pipeline (Substitutions, fillers, AI, Text Style) on the verbatim text and then calls `HistoryStore.resolveDiscarded`. The result goes to History only. Nothing is inserted or pasted. If processing fails, the entry stays discarded and the error shows. A run recorded with AI off has the label "AI off · <style>". Process with AI always runs with AI on.
- **AI Prompt Mode and Text Style are locked during Arming and Capturing**, on both surfaces, and unlock in Finalizing. The app dims the pills and ignores taps. The keyboard hides them and shows ✕ in their place. The coordinator and the keyboard controller refuse a cycle while locked, so the lock does not depend on a view. This reverses ADR-0004's amendment, which kept the pills usable for the whole run.

## Considered options

- **Keep hold-to-discard.** Rejected: STOP keeps two meanings and needs a warning, a countdown and a hint to explain itself.
- **Confirm before discard.** Rejected: an extra tap on every deliberate discard.
- **An Undo Window.** Rejected after it was built. The discarded run stays the active run, so the next dictation waits for the window to close, and the words are lost when it closes.
- **Keep the discarded run as the active run until it finalizes.** Rejected: it blocks a new run.
- **Decode the discarded run and the next run at the same time.** Rejected: it is not proven safe for WhisperKit's shared instance or for shared Core ML models.

## Consequences

- **A Discard always costs one on-device decode.** The user does not wait for it, but the next run's transcription setup can wait for it.
- **History holds entries with no output.** The History list must show them as discarded and offer Process with AI. A choice recorded on the Mac uses the current iOS style.
- **`.cancelling` replaces `.cancellingArming`.** The phase covers every run that tears down with no result: a Discard or stop during Arming, and a Shortcut start whose card the system refused.
- **A Shortcut start whose card the system refused cancels at once** and saves nothing. No speech was captured.
- **The Discard command keeps its freshness stamp** ([ADR-0003](0003-discard-queues-a-freshness-stamped-command.md)). The keyboard renders only wire-published terminal states ([ADR-0004](0004-keyboard-renders-only-wire-published-terminal-states.md)). The wire has no `discarded` token.
