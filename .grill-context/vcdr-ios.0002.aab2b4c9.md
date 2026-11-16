---
fragment: aab2b4c9
generation: 0002
branch: vcdr-mobile-remove-assistant
---

~ AI Prompt Mode
  The per-session choice of whether AI processes the dictated text. It has two values. Verbatim (AI off) keeps the text on the device. Dictation (AI on) improves dictated prose and never acts on what was said. The app and the keyboard say "AI off" and "AI on".
  was: The per-session choice for how dictated text should be interpreted: Verbatim leaves text local, Dictation improves dictated prose, and Assistant uses the transcript plus captures as assistant input. Verbatim is the canonical "AI off" mode.
  avoid: mode flag, prompt key, Assistant
  under: Output Choices

- Capture

~ Keyboard Channel
  The app-group channel between the iOS app and its custom keyboard extension. It carries recording commands, recording state, bundled transcription results, heartbeat, and shared session settings.
  was: The app-group channel between the iOS app and its custom keyboard extension. It carries recording commands, recording state, bundled transcription results, captures, heartbeat, and shared session settings.
  avoid: keyboard transport, IPC layer, shared defaults protocol
  under: Keyboard And App Reachability

~ Run Origin
  Where a Recording Run's record intent came from: the app, the keyboard, or a Shortcut. The start fixes it, and the trigger that stops the run never changes it. It alone decides the run's Completion Delivery destinations. A keyboard stop can end a Shortcut run, and the run still delivers as a Shortcut run. VCDR never writes a Shortcut run's text to the clipboard: iOS refuses that write from the background. The Stop Recording intent returns the text, and the Shortcut copies it.
  was: Where a Recording Run's record intent came from: the app, the keyboard, or a Shortcut. The start fixes it, and the trigger that stops the run never changes it. It alone decides the run's Completion Delivery destinations and whether the run reads and clears Captures. A keyboard stop can end a Shortcut run, and the run still delivers as a Shortcut run. A Shortcut run never reads or clears Captures, so it cannot consume Captures meant for a later keyboard run. VCDR never writes a Shortcut run's text to the clipboard: iOS refuses that write from the background. The Stop Recording intent returns the text, and the Shortcut copies it.
  avoid: fromDeepLink, sendToKeyboard, stop origin, trigger
  under: Recording And Delivery

~ Text Style
  The per-session choice for deterministic final text shape, currently Casual, Messaging, or Formal. Text Style is orthogonal to AI Prompt Mode and applies with AI on and with AI off.
  was: The per-session choice for deterministic final text shape, currently Casual, Messaging, or Formal. Text Style is orthogonal to AI Prompt Mode and applies only where the selected mode allows style transformations.
  avoid: formatting preset, tone, mode
  under: Output Choices

~ Transcript Finalization
  The deterministic final shaping step before text is shown, inserted, sent to the keyboard, or recorded in history. It applies the Text Style and the trailing terminator to filler-cleaned text or AI output.
  was: The deterministic final shaping step before text is shown, inserted, sent to the keyboard, or recorded in history. It applies mode-gated style transformation and the trailing terminator to filler-cleaned text or AI output.
  avoid: post-processing, formatting pipeline, final cleanup
  under: Output Choices

~ Transcript Processing
  The Recording Run policy that turns filler-cleaned recognized speech into user-facing output. It uses AI Prompt Mode, then applies Transcript Finalization and records the label for the output choices that shaped the result.
  was: The Recording Run policy that turns filler-cleaned recognized speech into user-facing output. It may use AI Prompt Mode and Captures, then applies Transcript Finalization and records the label for the output choices that shaped the result.
  avoid: AI retry path, formatter, post-processing
  under: Output Choices

~ Conversation
  A history record for one successful Recording Run. It stores the dictated input, optional AI-processed output, and a label for the output choices that shaped the result. A Conversation saved before Captures were retired can also hold captured context.
  was: A history record for one successful Recording Run. It stores the dictated input, any captures, optional AI-processed output, and a label for the output choices that shaped the result.
  avoid: transcript record, history item, run log
  under: History
