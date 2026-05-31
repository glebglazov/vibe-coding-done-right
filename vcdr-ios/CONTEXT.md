# VCDR iOS Context

VCDR iOS is a voice dictation product made of a main app, custom keyboard extension, and widget target. This context records iOS-specific language for keyboard-driven recording, transcription, assistant context, delivery, and per-session output choices.

## Language

### Keyboard And App Reachability

**Keyboard Channel**:
The app-group channel between the iOS app and its custom keyboard extension. It carries recording commands, recording state, bundled transcription results, captures, heartbeat, and shared session settings.
_Avoid_: keyboard transport, IPC layer, shared defaults protocol

**Heartbeat**:
The app-alive signal written by the main app while the Hot Mic Session is alive. The keyboard uses the heartbeat to choose between sending an in-place command and opening the app through a deep link.
_Avoid_: ping, liveness flag, alive bit

**Deep-Link Fallback**:
The keyboard's recovery path when the heartbeat is stale or a command is not acknowledged quickly enough. It opens the main app to start or stop recording when the in-keyboard command path cannot be trusted.
_Avoid_: URL workaround, app bounce, launch fallback

### Recording And Delivery

**Capture**:
Selected host-app text intentionally included as assistant context during a recording. A recording can have zero or more captures.
_Avoid_: selection blob, selected text payload

**Hot Mic Session**:
The app-level warm-microphone lifecycle that makes keyboard-driven recording start quickly. It owns app reachability, mic presence, and the user's hot-session timeout policy.
_Avoid_: warm engine, background mic mode

**Mic Presence**:
The user-visible indication that VCDR is responsible for the active microphone while the Hot Mic Session is warm. It exists to identify VCDR beside the system microphone indicator even when the user is not actively recording.
_Avoid_: live activity implementation, orange-dot label, mic badge

**Hot-Session Timeout**:
The user's policy for how long the Hot Mic Session stays warm after recording stops. It can mean never keep the mic warm, keep it warm for a finite idle window, or keep it warm for the app lifetime.
_Avoid_: idle timer, warm timeout, background duration

**Bundled Result**:
A final transcription result delivered to the keyboard through the Keyboard Channel together with the idle recording state. The keyboard consumes it once and then clears it.
_Avoid_: idle pipe text, state string payload

**Recording Run**:
The lifecycle of one user-initiated recording from start through finalization and completion delivery. A Recording Run has exactly one terminal state: success, empty result, cancellation, or processing failure.
_Avoid_: recording service, transcription pipeline, coordinator helper

**Completion Delivery**:
The handoff that applies a Recording Run terminal state to outside destinations such as the Keyboard Channel and conversation history. Completion Delivery must preserve the run result without making the Recording Run know which destinations are active.
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
A per-session override for an output choice, usually cycled from the recording UI or keyboard. Session Settings win over Default Settings during the current session and are cleared on cold launch.
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
