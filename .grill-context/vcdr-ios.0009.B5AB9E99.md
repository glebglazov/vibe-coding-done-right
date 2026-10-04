---
fragment: B5AB9E99
generation: 0009
branch: master
---

- Session Setting

+ Setting Override
  A user's pick for an output choice, usually cycled from the recording UI or keyboard, that wins over the matching Default Setting. A Setting Override survives launches and is cleared only when the user picks again or changes the matching Default Setting.
  avoid: Session Setting, temporary default, shared live value
  under: Output Choices

~ Default Setting
  A user-configured output preference that survives launches and applies wherever no Setting Override exists. Changing a Default Setting intentionally clears the matching Setting Override so the new default takes effect immediately.
  avoid: persistent session value, global live state
  was: A user-configured output preference that survives launches and seeds new sessions. Changing a Default Setting intentionally clears the matching Session Setting so the new default takes effect immediately.

~ AI Prompt Mode
  The output choice for how dictated text should be interpreted: Verbatim leaves text local, Dictation improves dictated prose, and Assistant uses the transcript plus captures as assistant input. Verbatim is the canonical "AI off" mode.
  avoid: AI toggle, mode flag, prompt key
  was: The per-session choice for how dictated text should be interpreted: Verbatim leaves text local, Dictation improves dictated prose, and Assistant uses the transcript plus captures as assistant input. Verbatim is the canonical "AI off" mode.

~ Text Style
  The output choice for deterministic final text shape, currently Casual, Messaging, or Formal. Text Style is orthogonal to AI Prompt Mode and applies only where the selected mode allows style transformations.
  avoid: formatting preset, tone, mode
  was: The per-session choice for deterministic final text shape, currently Casual, Messaging, or Formal. Text Style is orthogonal to AI Prompt Mode and applies only where the selected mode allows style transformations.

~ Keyboard Channel
  The app-group channel between the iOS app and its custom keyboard extension. It carries recording commands, recording state, bundled transcription results, captures, heartbeat, and Setting Overrides.
  avoid: keyboard transport, IPC layer, shared defaults protocol
  was: The app-group channel between the iOS app and its custom keyboard extension. It carries recording commands, recording state, bundled transcription results, captures, heartbeat, and shared session settings.

~ Session
  Do not use "session" by itself. Say Hot Mic Session for app-level microphone warmth, Recording Run for one recording lifecycle, Setting Override for a user's pick that wins over a Default Setting, and Conversation for saved history.
  was: Do not use "session" by itself. Say Hot Mic Session for app-level microphone warmth, Recording Run for one recording lifecycle, Session Setting for a per-session output override, and Conversation for saved history.
