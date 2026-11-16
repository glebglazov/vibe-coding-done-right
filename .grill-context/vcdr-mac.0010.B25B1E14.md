---
fragment: B25B1E14
generation: 0010
branch: vcdr-mobile-remove-assistant
---

~ Mode Template
  A built-in definition used to seed or reset a Mode: AI off or AI on. A Mode Template is not the user's live Mode instance.
  was: A built-in definition used to seed or reset a Mode, such as Verbatim, Dictation, Assistant (Remote), or Assistant (Local). A Mode Template is not the user's live Mode instance.

~ Processing Type
  The kind of transformation a Mode applies before output delivery: no external processing, cloud AI, or bash script. Processing Type is about text transformation, not where the final text is delivered.
  was: The kind of transformation a Mode applies before output delivery: no external processing, cloud AI, local agent, or bash script. Processing Type is about text transformation, not where the final text is delivered.

~ Mode
  The selected processing recipe for a Capture Session. A Mode defines how dictated text is transformed, whether preview is shown, which destination is default, which parameters are available, and whether Cursor Context applies.
  was: The selected processing recipe for a Capture Session. A Mode defines how dictated text is transformed, whether preview is shown, which destination is default, which parameters are available, and whether styles or Cursor Context apply.

+ Retired Mode
  A saved Mode that the removal of the Assistant deleted: a Mode from the Assistant (Remote) or Assistant (Local) Mode Template, or a Mode with the local agent Processing Type. VCDR keeps its id and name, so that it can delete the History entries of the Mode at every launch.
  avoid: deleted mode, old assistant, legacy mode
  under: Modes And Processing

- No Instruction

~ Capture Panel
  The floating macOS UI surface shown during a Capture Session for recording state, the Cursor Context indicator, preview, errors, and confirmation controls.
  was: The floating macOS UI surface shown during a Capture Session for recording state, captured context indicators, preview, errors, and confirmation controls.

- Capture

- Selection Capture

- Clipboard Capture

- Capture Layer

- Capture Use

~ Cursor Context
  Text immediately before and after the insertion point in the source app, read through Accessibility at the start of a Capture Session. The read posts no Synthetic Keystroke. Context-aware modes may use Cursor Context for formatting and AI input, and it is discarded when it no longer matches the target app.
  was: Text immediately before and after the insertion point in the source app. Context-aware modes may use Cursor Context for formatting and AI input, and it is discarded when it no longer matches the target app.

~ Style
  The output-shaping choice that controls capitalization, punctuation, trailing spacing, and optional style prompt behavior. Style is orthogonal to Mode and applies in every Mode.
  was: The output-shaping choice that controls capitalization, punctuation, trailing spacing, and optional style prompt behavior. Style is orthogonal to Mode and only applies when the Mode allows styles.

~ Input Segment
  A part of a Conversation's input. A new Conversation has one Input Segment, the dictated text. A Conversation saved before Captures were removed can also hold captured text.
  was: A part of a Conversation's input, either dictated text or a Capture. A Conversation has one or more Input Segments.

~ Synthetic Keystroke
  A key event VCDR posts itself to drive another application, such as the Command-V of a Paste. A Synthetic Keystroke carries only the modifiers VCDR assigns to it; it is not a key the user pressed, and the target application can treat it differently from a pressed key.
  was: A key event VCDR posts itself to drive another application, such as the Command-C of a Capture Layer or the Command-V of a Paste. A Synthetic Keystroke carries only the modifiers VCDR assigns to it; it is not a key the user pressed, and the target application can treat it differently from a pressed key.

~ Keystroke Passthrough
  The behaviour of a target application that neither acts on a Synthetic Keystroke nor discards it, and instead forwards it to whatever the application hosts. Keystroke Passthrough turns a Paste into a Stray Character in the hosted program.
  was: The behaviour of a target application that neither acts on a Synthetic Keystroke nor discards it, and instead forwards it to whatever the application hosts. Keystroke Passthrough turns a Capture Layer or a Paste into a Stray Character in the hosted program.
