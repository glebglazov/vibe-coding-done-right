# VCDR iOS Context

VCDR iOS is a voice dictation product made of a main app, custom keyboard extension, and widget target. This context records iOS-specific language for keyboard-driven recording, transcription, assistant context, delivery, and per-session output choices.

## Language

### Keyboard And App Reachability

**Keyboard Channel**:
The app-group channel between the iOS app and its custom keyboard extension. It carries recording commands, recording state, bundled transcription results, captures, heartbeat, and shared session settings. Each key has one writer: the app writes its snapshot (the newest Recording Run, its phase, and the commands it took) and the Heartbeat; the keyboard writes its commands, each with its own ID.
_Avoid_: keyboard transport, IPC layer, shared defaults protocol

**Heartbeat**:
The app-alive signal written by the main app while the Hot Mic Session is alive and reachable. The keyboard uses the heartbeat to choose whether to attempt an in-place command; command acknowledgement is still required to prove the path is working right now.
_Avoid_: ping, liveness flag, alive bit

**In-Place Reachability**:
Whether the next keyboard start will record where the user is typing, rather than need the Deep-Link Fallback. One predicate decides it: a Heartbeat younger than the keyboard's freshness window. The keyboard and Mic Presence both render that one predicate.
_Avoid_: app alive, warm, connected

**Deep-Link Fallback**:
The keyboard's recovery path when the heartbeat is stale or a command is not acknowledged quickly enough. It opens the main app to start or stop recording when the in-keyboard command path cannot be trusted.
_Avoid_: URL workaround, app bounce, launch fallback

**Command Acknowledgement**:
The app's confirmation, by the command's ID, that it took a Keyboard Channel command. Acknowledgement proves command reachability; it does not by itself mean audio is already Capturing, and it holds even when the run the command started has already ended.
_Avoid_: recording state, start state, command sent

### Recording And Delivery

**Capture**:
Selected host-app text intentionally included as assistant context during a recording. A recording can have zero or more captures.
_Avoid_: selection blob, selected text payload

**Hot Mic Session**:
The app-level warm-microphone lifecycle that makes keyboard-driven recording start quickly. It owns In-Place Reachability (through the Heartbeat) and the user's Hot-Session Timeout policy, and reports that reachability to Mic Presence.
_Avoid_: warm engine, background mic mode

**Mic Presence**:
The user-visible card that says, from outside the app, what VCDR is doing with the microphone. It renders In-Place Reachability and the progress of the active Recording Run: ready while the Hot Mic Session is warm and reachable, then Arming, Capturing with a running timer, and Finalizing. For a Run Origin with no surface of its own, it also shows a short outcome (transcribed, no speech, failed). If Mic Presence says VCDR is ready, a keyboard start should be expected to record in place rather than require Deep-Link Fallback. It never makes a claim it cannot withdraw: when the app stops renewing it, iOS shows it as not ready. It is absent while VCDR is in the foreground, except while a Shortcut run is Arming or Capturing, because the system stops a Shortcut recording that has no card. It offers Cancel while Arming and Stop while Capturing, except for a Shortcut run: that run's text reaches the user only through the Stop Recording intent, so the card only shows that it records. For a finite Hot-Session Timeout, Mic Presence should end around the timeout deadline rather than remain visible as a stale readiness signal.
_Avoid_: live activity implementation, orange-dot label, mic badge

**Readiness Fail-Closed**:
The Hot Mic Session teardown rule that user-visible readiness must disappear when the app can no longer uphold keyboard-driven recording. Teardown intends to stop the engine, clear the Heartbeat, and end Mic Presence together; if lower-level audio release fails, Heartbeat and Mic Presence still close so VCDR does not advertise readiness it cannot honor.
_Avoid_: partial teardown, best-effort cleanup

**Presence Deadline**:
The wall-clock deadline after which Mic Presence must stop advertising readiness. For a finite Hot-Session Timeout, the Presence Deadline is the Hot-Session Timeout deadline; for Always, there is no inactivity Presence Deadline, but Mic Presence still depends on keyboard reachability.
_Avoid_: stale date, widget expiry, live activity timeout

**Hot-Session Timeout**:
The user's wall-clock policy for how long the Hot Mic Session stays warm after recording stops. It can mean never keep the mic warm, keep it warm for a finite idle window, or keep it warm for the app lifetime. A finite timeout is measured from the start of idleness even while the app is backgrounded; once it expires, Mic Presence should stop saying VCDR is ready.
_Avoid_: idle timer, warm timeout, background duration

**Bundled Result**:
A final transcription result delivered to the keyboard through the Keyboard Channel as the outcome of its Recording Run. The keyboard inserts it once and then remembers that run as settled; it never clears the app's state.
_Avoid_: idle pipe text, state string payload

**Recording Run**:
The lifecycle of one user-initiated recording from start through finalization and completion delivery. A Recording Run has exactly one terminal state: success, empty result, cancellation, or processing failure.
A Recording Run begins at the user's record intent — the tap — not when audio starts, and moves through three phases: **Arming**, **Capturing**, **Finalizing** (below). A run cancelled while still Arming (the user stops before audio ever flows) terminates in cancellation, having captured nothing.
_Avoid_: recording service, transcription pipeline, coordinator helper

**Run Origin**:
Where a Recording Run's record intent came from: the app, the keyboard, or a Shortcut. The start fixes it, and the trigger that stops the run never changes it. It alone decides the run's Completion Delivery destinations and whether the run reads and clears Captures. A keyboard stop can end a Shortcut run, and the run still delivers as a Shortcut run. A Shortcut run never reads or clears Captures, so it cannot consume Captures meant for a later keyboard run. VCDR never writes a Shortcut run's text to the clipboard: iOS refuses that write from the background. The Stop Recording intent returns the text, and the Shortcut copies it.
_Avoid_: fromDeepLink, sendToKeyboard, stop origin, trigger

**Arming**:
The first phase of a Recording Run: the record intent has been acknowledged and the audio engine is warming, but no audio is being captured yet. Arming is about the audio engine, never the transcription model — it is unrelated to Transcription Readiness. The UI shows the tap was registered (pressed, "preparing") but must not show a running timer or live waveform, because nothing is being captured.
_Avoid_: PREPARING (that is reserved against Transcription Readiness), warming, engine init state

**Capturing**:
The Recording Run phase where audio is actually flowing into the buffer and the live recording UI is truthful: timer running, waveform moving. Capturing may begin before Transcription Readiness; the transcription model catches up at Finalizing.
_Avoid_: recording state, live mic, listening

**Finalizing**:
The Recording Run phase after the user stops: capture has ended and the buffered audio awaits transcription, which may still be waiting on Transcription Readiness. The UI is truthful about the stop (button released, timer stopped, waveform frozen) and surfaces that transcription is pending rather than presenting a result that does not exist yet. If the model fails to load, the run terminates in processing failure.
_Avoid_: post-processing, finishing, transcribing state

**Completion Delivery**:
The handoff that applies a Recording Run terminal state to outside destinations such as the Keyboard Channel and conversation history. The Run Origin chooses the destinations. Completion Delivery must preserve the run result without making the Recording Run know which destinations are active. When History Bootstrap has not finished yet, a successful run's Conversation may be held and written once the history store is ready.
_Avoid_: callback, post-processing hook, output side effect

**Empty Result**:
A completed recording that produced no usable speech. Empty Result is distinct from cancellation and processing failure because the keyboard can surface it as a short no-speech state rather than a delivered transcript.
_Avoid_: blank transcript, no result, silent failure

### Output Choices

**AI Prompt Mode**:
The per-session choice for how dictated text should be interpreted: Verbatim leaves text local, Dictation improves dictated prose, and Assistant uses the transcript plus captures as assistant input. Verbatim is the canonical "AI off" mode.
_Avoid_: AI toggle, mode flag, prompt key

**Text Style**:
The per-session choice for deterministic final text shape, currently Casual, Messaging, or Formal. Text Style is orthogonal to AI Prompt Mode and applies only where the selected mode allows style transformations.
_Avoid_: formatting preset, tone, mode

**Default Setting**:
A user-configured output preference that survives launches and seeds new sessions. Changing a Default Setting intentionally clears the matching Session Setting so the new default takes effect immediately.
_Avoid_: persistent session value, global live state

**Session Setting**:
A per-session override for an output choice, usually cycled from the recording UI or keyboard. Session Settings win over Default Settings and survive launches, because iOS can end the app at any time without the user noticing. Changing the matching Default Setting clears a Session Setting.
_Avoid_: temporary default, shared live value

**Transcript Finalization**:
The deterministic final shaping step before text is shown, inserted, sent to the keyboard, or recorded in history. It applies mode-gated style transformation and the trailing terminator to filler-cleaned text or AI output.
_Avoid_: post-processing, formatting pipeline, final cleanup

**Transcript Processing**:
The Recording Run policy that turns filler-cleaned recognized speech into user-facing output. It may use AI Prompt Mode and Captures, then applies Transcript Finalization and records the label for the output choices that shaped the result.
_Avoid_: AI retry path, formatter, post-processing

### AI Backends

**AI Provider**:
The iOS-selectable backend for AI Prompt Mode processing. Cloud providers wrap the shared Cloud AI Backend; Apple is a platform-only case registered when AFM is available. Settings pickers use configured providers — not an unfiltered list of all cases. Persisted settings keep flat raw strings (`"anthropic"`, `"apple"`) for backward compatibility.
_Avoid_: LLM adapter, cloud enum, shared backend list

**Apple Backend**:
The on-device AFM backend available only on iOS when Apple Intelligence is ready. It is registered through AI Provider selection and AI Provider Selection; it is not part of the shared Cloud AI Backend enum or Model Catalog. Its LLM Adapter implementation stays in the iOS target.
_Avoid_: Apple provider case in Shared, AFM model picker, cloud adapter

### App Readiness

**Transcription Readiness**:
The point at which the on-device speech recognition model is loaded and ready to transcribe. A Recording Run may start before Transcription Readiness; audio is captured immediately and transcription catches up once the model is ready.
_Avoid_: PREPARING, model init, compiling state

**Model Warming**:
The user-visible launch state when transcription-model artifacts already exist on disk but Transcription Readiness has not landed yet. The main app may show the ready hero with a subtle warming indicator because a Recording Run can begin immediately and transcription will catch up at Finalizing. Model Warming is about pending Transcription Readiness, not the audio-engine Arming phase after a record tap.
_Avoid_: Arming, PREPARING, Capturing

**App Shell**:
The parts of the main app that do not depend on Transcription Readiness — navigation, settings, conversation history, and debug tools. The App Shell stays fully usable while Transcription Readiness is pending.
_Avoid_: launch screen, boot gate, init blocker

**Launch Verdict**:
The classification of one launch's transcription-model load cost: Cold Download (model artifacts had to be fetched), Cold Specialize (artifacts were on disk but the system's ANE specialization cache was purged — reboot, OS or app update, storage pressure — forcing a re-grind), or Warm (all loads hit caches). The verdict explains why a launch was slow; each launch's verdict and timings are persisted as launch telemetry. Cold Specialize recurs in normal life — it is not a first-install-only event.
_Avoid_: cold start (ambiguous between download and specialization), first launch, slow launch

**History Bootstrap**:
The launch step that opens the Local Store and installs the active history store from it. It touches on-device storage only, so it completes quickly enough to be invisible. The Sync Reconciler — resolving the iCloud container, merging the Record Files in, exporting whatever the store still owes — starts behind it, and no read waits for that. While History Bootstrap is pending, the history screen is reachable and shows a loading state rather than blocking navigation.
_Avoid_: iCloud init, bootstrapHistory, store factory

### History

**Conversation**:
A history record for one successful Recording Run. It stores the dictated input, any captures, optional AI-processed output, and a label for the output choices that shaped the result.
_Avoid_: transcript record, history item, run log

**Input Segment**:
A part of a Conversation's input, either dictated text or captured context. A Conversation has one or more input segments.
_Avoid_: turn, message, text chunk

## Flagged Ambiguities

**Session**:
Do not use "session" by itself. Say Hot Mic Session for app-level microphone warmth, Recording Run for one recording lifecycle, Session Setting for a per-session output override, and Conversation for saved history.

## Example Dialogue

Dev: "The keyboard published a stop command on the Keyboard Channel, but no Bundled Result arrived."

Domain expert: "Was the Hot Mic Session still alive? If the heartbeat was stale, the keyboard should use the Deep-Link Fallback and wait for the app to publish the Bundled Result on next appearance."

Dev: "The AI Prompt Mode was Assistant and the recording had two captures."

Domain expert: "Keep the captures as Input Segments in the Conversation, but deliver only the final assistant response as the Bundled Result."

Dev: "The user cycled from Formal to Messaging on the keyboard before stopping."

Domain expert: "That is a Session Setting. It wins for this Recording Run, but it does not change the Default Setting for future launches."

Dev: "The Recording Run ended with an Empty Result."

Domain expert: "Publish Empty Result to the keyboard if it was keyboard-driven; do not create a Conversation."

Dev: "The user started recording from the Start Recording shortcut and stopped it from the keyboard."

Domain expert: "The Run Origin is still Shortcut. The text goes to history, Mic Presence shows it was transcribed, and the keyboard only goes back to idle. No Stop Recording intent ran, so no Shortcut got the text."
