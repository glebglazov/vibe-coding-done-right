# VCDR iOS Context

VCDR iOS is a voice dictation app with a main app, custom keyboard extension, and widget target. This context records iOS-specific language for app/keyboard recording, transcription, and delivery concepts.

## Language

**Keyboard Channel**:
The app-group channel between the iOS app and its custom keyboard extension. It carries recording commands, recording state, bundled transcription results, captures, heartbeat, and shared session settings.
_Avoid_: keyboard transport, IPC layer, shared defaults protocol

**Capture**:
Selected host-app text intentionally included as assistant context during a recording. A recording can have zero or more captures.
_Avoid_: selection blob, selected text payload

**Hot Mic Session**:
The lifecycle of the app's warm audio engine: the period it keeps the engine ready so keyboard-driven recording starts without relaunch or cold audio setup, plus the heartbeat that tells the Keyboard Channel the app is reachable, the Live Activity presence shown beside the system mic indicator while warm, and the inactivity-timeout policy (`.never` / `.always` / finite) that tears it down.
_Avoid_: warm engine, background mic mode

**Bundled Result**:
A final transcription result delivered to the keyboard through the Keyboard Channel together with the idle recording state. The keyboard consumes it once and then clears it.
_Avoid_: idle pipe text, state string payload

**Recording Run**:
The lifecycle of one user-initiated recording from start through finalization and completion delivery. It owns recording/transcription/AI/finalization ordering and hands terminal completion states to injected completion adapters, such as Keyboard Channel delivery or history recording, without hard-wiring those concrete mechanisms into the run. Terminal states include success, empty result, cancellation, and processing failure. Keyboard Channel failure delivery is an extension point, not an initial requirement; the first extraction may map failures to existing idle/no-result behavior while preserving the failure state for a later keyboard-facing message.

The UI-facing recording coordinator remains responsible for observable UI state, app lifecycle and deep-link entry points, creating or starting a Recording Run, forwarding user commands, and presenting high-level status or errors. It should not own per-run ordering once the Recording Run has started.
_Avoid_: recording service, transcription pipeline, coordinator helper

## Example Dialogue

Dev: "The keyboard published a stop command on the Keyboard Channel, but no bundled result arrived."

Domain expert: "Was the Hot Mic Session still alive? If the heartbeat was stale, the keyboard should use the URL fallback and wait for the app to publish the bundled result on next appearance."

Dev: "Assistant mode had two captures, so the app should include both captures when building the AI input before publishing the bundled result."

Dev: "The Recording Run finalized the transcript and passed the terminal completion state to the Keyboard Channel completion adapter."
