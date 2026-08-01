---
fragment: 74E93D88
generation: 0002
branch: master
---

+ Hold Threshold
  The total time Stop must be held before Discard fires — three seconds, made of the Discard Dwell followed by the Discard Warning ramp. Reaching it discards without waiting for release; releasing before it always performs a normal stop.
  avoid: long-press duration, cancel timeout, hold time
  under: Recording And Delivery

+ Discard Dwell
  The first second of a Stop hold, during which nothing changes on screen. It separates a tap-to-stop and an idle finger from a deliberate hold, so the Discard Warning only appears once intent is unambiguous.
  avoid: grace period, delay, debounce
  under: Recording And Delivery

+ Discard Warning
  The escalating destructive state shown after the Discard Dwell and until the Hold Threshold: the surface around the Stop control reddens as the remaining time runs down, with haptic ticks accelerating toward the moment of discard. It warns without renaming Stop, because releasing still stops.
  avoid: cancel animation, countdown, progress feedback
  under: Recording And Delivery

+ Discard Hint
  The persistent instruction that teaches the hold gesture, shown while a Recording Run is in progress. It is stationary and unchanging — the Discard Warning, not the hint, carries the escalation.
  avoid: coach mark, tooltip, onboarding tip
  under: Recording And Delivery

~ Compact Keyboard
  The custom keyboard's reduced state: no key rows, only VCDR's dictation controls, next-keyboard access, and a reserved row above them that carries the Discard Hint. It is the keyboard's default state, and the user switches to the Full Keyboard when they want to type. The reserved row is present at every moment, recording or not, so nothing reflows mid-hold.
  was: The custom keyboard's reduced state: no key rows, only VCDR's dictation controls and next-keyboard access, so the keyboard claims as little screen as a dictation surface needs. It is the keyboard's default state, and the user switches to the Full Keyboard when they want to type.
  avoid: collapsed keyboard (KeyboardKit's own term for hardware-keyboard autocollapse), mini keyboard, strip mode
