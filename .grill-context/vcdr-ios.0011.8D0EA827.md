---
fragment: 8D0EA827
generation: 0011
branch: master
---

~ Discard
  The user's intent to end a Recording Run without inserting text, given with the ✕ DISCARD control, never with STOP. A Discard ends the run at once, so the user can start the next run immediately. A Discard during Capturing keeps the words: when the run has speech, its verbatim on-device transcript and its captures go to History as a Discarded Conversation. A Discard during Arming keeps nothing, because no audio exists. A discarded run never produces a Bundled Result and never inserts text.
  avoid: cancel button, abort, stop-and-delete, hold to discard, undo
  was: The user's intent to end a Recording Run without producing text, expressed by holding Stop past the hold threshold. A discarded run terminates in cancellation: no Bundled Result, no Conversation, captures cleared. The Hot Mic Session stays warm, so the next recording starts as fast as any other.

~ Conversation
  A history record for one Recording Run that produced text, or for one discarded run that had speech. It stores the dictated input, any captures, optional AI-processed output, and a label for the output choices that shaped the result. A Discarded Conversation has no output until the user processes it with AI.
  avoid: transcript record, history item, run log
  was: A history record for one successful Recording Run. It stores the dictated input, any captures, optional AI-processed output, and a label for the output choices that shaped the result.
  under: History

~ Setting Override
  A user's pick for an output choice, usually cycled from the recording UI or keyboard, that wins over the matching Default Setting. It cannot change while a Recording Run is Arming or Capturing; it unlocks at Finalizing. A Setting Override survives launches and is cleared only when the user picks again or changes the matching Default Setting.
  avoid: Session Setting, temporary default, shared live value
  was: A user's pick for an output choice, usually cycled from the recording UI or keyboard, that wins over the matching Default Setting. A Setting Override survives launches and is cleared only when the user picks again or changes the matching Default Setting.

~ Compact Keyboard
  The custom keyboard's reduced state: no key rows, only VCDR's dictation controls and next-keyboard access. It is the keyboard's default state, and the user switches to the Full Keyboard when they want to type. Its height never changes: during a run, the Discard control takes the settings pills' place on the same row.
  avoid: collapsed keyboard (KeyboardKit's own term for hardware-keyboard autocollapse), mini keyboard, strip mode
  was: The custom keyboard's reduced state: no key rows, only VCDR's dictation controls, next-keyboard access, and a reserved row above them that carries the Discard Hint. It is the keyboard's default state, and the user switches to the Full Keyboard when they want to type. The reserved row is present at every moment, recording or not, so nothing reflows mid-hold.

- Hold Threshold

- Discard Dwell

- Discard Warning

- Discard Hint
