# VCDR macOS Context

VCDR macOS is a menu bar dictation product that records speech, reads the text around the cursor, processes text through a selected mode, and delivers the result to a chosen destination. This context records macOS-specific language for the Capture Session, mode processing, style resolution, preview, and output delivery.

## Language

### Capture Lifecycle

**Capture Session**:
The lifecycle of one macOS dictation run from hotkey start through recording, transcription, processing, preview or execution, and return to idle. A Capture Session has one active run state at a time.
_Avoid_: recording coordinator, capture coordinator, workflow

**Capture Panel**:
The floating macOS UI surface shown during a Capture Session for recording state, captured context indicators, preview, errors, and confirmation controls.
_Avoid_: overlay, popup, transcription panel

**Recording Indicator**:
The lightweight menu-bar or pill feedback that communicates capture status outside the Capture Panel. It is not the Capture Session itself.
_Avoid_: status label, menu icon, recording state

**Suspension**:
A temporary pause of capture hotkey behavior while another UI flow needs exclusive keyboard focus. Suspension is released explicitly or when its token is discarded.
_Avoid_: disabled state, pause, lockout

### Context Capture

**Capture**:
External text intentionally included with the dictation as context. A Capture can come from the initial selection or from clipboard changes collected during recording.
_Avoid_: snippet, selection blob, copied text

**Selection Capture**:
The initial attempt to read selected text from the frontmost app at the start of a Capture Session. It may also produce Cursor Context.
_Avoid_: selected text grab, AX scrape, prefill

**Clipboard Capture**:
Additional text captured from clipboard changes while a Capture Session is recording. Clipboard Capture is separate from Selection Capture and is appended after the selection capture.
_Avoid_: copy monitor result, pasteboard sample, clipboard history

**Cursor Context**:
Text immediately before and after the insertion point in the source app. Context-aware modes may use Cursor Context for formatting and AI input, and it is discarded when it no longer matches the target app.
_Avoid_: surrounding text, insertion context, AX context

**Initial App**:
The frontmost app when a Capture Session starts. Paste to Initial App restores this app before delivering output.
_Avoid_: source app, previous app, target app

### Modes And Processing

**Mode**:
The selected processing recipe for a Capture Session. A Mode defines how dictated text is transformed, whether preview is shown, which destination is default, which parameters are available, and whether styles or Cursor Context apply.
_Avoid_: profile, preset, prompt

**Mode Template**:
A built-in definition used to seed or reset a Mode, such as Verbatim, Dictation, Assistant (Remote), or Assistant (Local). A Mode Template is not the user's live Mode instance.
_Avoid_: built-in mode, default mode, template preset

**Processing Type**:
The kind of transformation a Mode applies before output delivery: no external processing, cloud AI, local agent, or bash script. Processing Type is about text transformation, not where the final text is delivered.
_Avoid_: action type, destination type, provider

**Cloud AI Provider**:
The macOS name for a cloud backend on a Mode with Processing Type cloud AI. It is a typealias to the shared Cloud AI Backend — not a separate enum. Mode pickers and persistence use the shared identity directly.
_Avoid_: AIProvider enum, platform backend list, LLM adapter

**Mode Parameter**:
A named per-mode choice whose selected option is passed into processing as a `VCDR_PARAM_*` value. A Capture Session may override Mode Parameters without changing the Mode's defaults.
_Avoid_: setting, option, variable

**Session Override**:
A temporary per-Capture-Session choice that supersedes a Mode default, such as a Mode Parameter or Output Destination. Session Overrides are cleared when that Capture Session completes or is cancelled.
_Avoid_: setting change, temporary default, pending override

**No Instruction**:
An AI processing outcome meaning the dictation did not contain an actionable instruction. No Instruction is distinct from empty speech because transcription succeeded but the selected Mode declined to act.
_Avoid_: empty result, AI failure, ignored command

**AI Fallback Preview**:
A preview shown when AI processing fails and VCDR falls back to locally structured text. It keeps enough retry context for another AI attempt while preserving user-visible text.
_Avoid_: AI error state, retry panel, fallback result

### Output Delivery

**Output Destination**:
The chosen delivery target for processed text. Built-in destinations include Paste, Paste to Initial App, and Copy; user-created destinations currently run bash scripts.
_Avoid_: action, sink, exporter

**Destination Override**:
A Session Override that selects an Output Destination for the current Capture Session. A Destination Override skips preview even when the Mode normally requires preview.
_Avoid_: quick action, output shortcut, destination hotkey

**Preview**:
The confirmation state where processed text is shown before delivery. Preview is controlled by the Mode unless a Destination Override forces immediate execution.
_Avoid_: review screen, draft, output panel

**Confirmation**:
The user's approval of a Preview, optionally with a different Output Destination. Confirmation delivers the preview text and records history.
_Avoid_: submit, accept, execute

**Concealed Paste**:
Delivery that temporarily writes the result to the clipboard, simulates paste, and restores the previous clipboard contents. Concealed Paste is used when the result should not remain on the clipboard.
_Avoid_: hidden copy, temporary clipboard, paste trick

### Styles

**Style**:
The output-shaping choice that controls capitalization, punctuation, trailing spacing, and optional style prompt behavior. Style is orthogonal to Mode and only applies when the Mode allows styles.
_Avoid_: tone, format, casing preset

**Detected Style**:
The Style selected from the frontmost app's bundle ID through the style registry. Detected Style is the baseline before any Style Override. Detected Style keeps updating as the frontmost app changes even when a Style Override is active.
_Avoid_: app style, automatic style, inferred style

**Effective Style**:
The Style actually used for output: Style Override when active, otherwise Detected Style. Capture Session reads Effective Style at processing time.
_Avoid_: current style, resolved style, active style

**Style Override**:
A user-chosen Style that replaces Detected Style as the effective Style until cleared. Style Override persists across Capture Sessions and app launches; it is cleared only when the user cycles back to Detected Style or chooses Clear from the menu bar. Style Override is not a Session Override. Capture Session processing reads Effective Style at processing time, not at recording start.
_Avoid_: style setting, manual style, forced style, session override

**Context-Aware Formatting**:
Style behavior that uses Cursor Context to decide leading capitalization and separator insertion. It is available only when the Mode opts into Cursor Context.
_Avoid_: smart formatting, cursor formatting, adaptive punctuation

### History

**Conversation**:
A history record for a Capture Session that reaches preview or execution. It stores input segments, optional externally processed output, and the Mode label.
_Avoid_: transcription record, capture log, history item

**Input Segment**:
A part of a Conversation's input, either dictated text or a Capture. A Conversation has one or more Input Segments.
_Avoid_: turn, message, text chunk

## Flagged Ambiguities

**Session**:
Do not use "session" by itself. Say Capture Session for one macOS dictation lifecycle and Session Override for temporary per-Capture-Session choices. Style Override spans the app run, not a single Capture Session.

**Destination vs Processing**:
Processing Type transforms text before delivery; Output Destination delivers the processed text afterward. Do not call a destination a processing action.

**Style vs Mode**:
Mode decides the processing recipe; Style decides final text shape. Every Mode applies the Style.

**Style Override vs Detected Style**:
Style Override masks Detected Style for output but does not stop Detected Style from updating. Clearing Style Override restores the current Detected Style, not the one from when the override was set.

## Example Dialogue

Dev: "The user pressed the destination hotkey while recording in a preview Mode."

Domain expert: "That creates a Destination Override. The Capture Session should skip Preview and execute the selected Output Destination directly."

Dev: "The frontmost app changed from Safari to Mail during recording."

Domain expert: "Check whether the Cursor Context is still valid for the Initial App or target app. If it is stale, discard it before Context-Aware Formatting or AI input."

Dev: "The user cycled Formal from the mode switcher before stopping."

Domain expert: "That is a Style Override. It stays in effect for the next Capture Session too, until they cycle back to Detected Style. It does not change Mode defaults or the Style registry mapping for the frontmost app."

Dev: "The user cancelled mid-recording with an active Style Override."

Domain expert: "Style Override survives cancel — it is not a Session Override. Only destination and parameter overrides reset with that Capture Session."

Dev: "The user pressed the recording hotkey while the menu bar still shows an orange dot."

Domain expert: "The Capture Session starts and records. Backend Rejection does not apply to the transcription model — the hotkey is never refused for it. The pill names the Model Preparation Phase from the start, and the run waits for the model after the user stops, where it says the recording is safe."

Dev: "The app was launched for the first time and iCloud container provisioning is still in progress."

Domain expert: "Shell-first Initialization means the MenuBarExtra and Settings window render regardless. The menu bar names the Model Preparation Phase; it does not gate recording on it. History and audio device enumeration catch up in the background."

Dev: "A Capture Session completed before the history store finished initializing."

Domain expert: "The shell queued the history write in memory and flushed it once the store became ready. The Conversation is not lost."
