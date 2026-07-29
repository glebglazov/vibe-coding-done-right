---
fragment: DD337258
generation: 0001
branch: master
---

+ Compact Keyboard
  The custom keyboard's reduced state: no key rows, only VCDR's dictation controls and next-keyboard access, so the keyboard claims as little screen as a dictation surface needs. It is the keyboard's default state, and the user switches to the Full Keyboard when they want to type.
  avoid: collapsed keyboard (KeyboardKit's own term for hardware-keyboard autocollapse), mini keyboard, strip mode
  under: Keyboard And App Reachability

+ Full Keyboard
  The custom keyboard's typing state: key rows plus the toolbar strip carrying VCDR's dictation controls. Switching between Full and Compact never reloads the keyboard — both states are the same live keyboard.
  avoid: expanded keyboard, big keyboard, normal mode
  under: Keyboard And App Reachability

+ Discard
  The user's intent to end a Recording Run without producing text, expressed by holding Stop past the hold threshold. A discarded run terminates in cancellation: no Bundled Result, no Conversation, captures cleared. The Hot Mic Session stays warm, so the next recording starts as fast as any other.
  avoid: cancel button, abort, stop-and-delete
  under: Recording And Delivery
