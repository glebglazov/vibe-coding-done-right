---
fragment: 363B7329
generation: 0004
branch: master
---

+ Hotkey Registration
  The claim VCDR holds on one key combination with macOS. While the claim is held the combination reaches VCDR and never the frontmost app; releasing it returns the combination to the frontmost app. There is no third state: VCDR cannot watch a combination without taking it, so a hotkey that should do nothing is one that is not registered.
  avoid: hotkey enabled, hotkey suppressed, event tap, listener, hotkey monitor
  under: Capture Lifecycle

+ Modifier Expansion
  The set of key combinations one Activation Hotkey claims. An Activation Hotkey matches any combination that includes its own modifiers, so it expands to every such combination that no more specific Activation Hotkey already claims. Expansion is what lets a destination fire while other modifiers are held.
  avoid: superset matching, fuzzy match, modifier wildcard
  under: Output Delivery

~ Suspension
  A temporary release of every Hotkey Registration while another UI flow needs exclusive keyboard focus, so the combinations reach that flow instead of VCDR. Suspension is held by a token and every Registration is restored when the token is released or discarded.
  was: A temporary pause of capture hotkey behavior while another UI flow needs exclusive keyboard focus. Suspension is released explicitly or when its token is discarded.

~ Activation Hotkey
  The key combination on an Output Destination that, pressed while a Capture Session is recording, creates a Destination Override for that Capture Session. An Activation Hotkey claims its whole Modifier Expansion, and only while the Capture Session is recording. Binding, re-binding or clearing one takes effect for the next key press rather than at the next launch.
  was: The key combination on an Output Destination that, pressed while a Capture Session is recording, creates a Destination Override for that Capture Session. An Activation Hotkey is armed from the live Output Destination list, so binding, re-binding or clearing one takes effect for the next key press rather than at the next launch.
