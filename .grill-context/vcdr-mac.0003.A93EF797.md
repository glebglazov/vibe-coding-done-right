---
fragment: A93EF797
generation: 0003
branch: master
---

+ Synthetic Keystroke
  A key event VCDR posts itself to drive another application, such as the Command-C of a Capture Layer or the Command-V of a Paste. A Synthetic Keystroke carries only the modifiers VCDR assigns to it; it is not a key the user pressed, and the target application can treat it differently from a pressed key.
  avoid: simulated key, fake keypress, CGEvent

+ Capture Layer
  One of the ordered attempts Selection Capture makes to read the selection from the frontmost app. Each Capture Layer is tried only after the one before it gives no text, and the last one is the only one that uses a Synthetic Keystroke.
  avoid: fallback, strategy, capture path

+ Stray Character
  A character that appears in the frontmost app during or after a Capture Session which the user did not press and which is not part of the delivered output. A Stray Character is attributed to whichever component put it there, which is not always VCDR.
  avoid: ghost character, phantom key, artefact

+ Keystroke Passthrough
  The behaviour of a target application that neither acts on a Synthetic Keystroke nor discards it, and instead forwards it to whatever the application hosts. Keystroke Passthrough turns a Capture Layer or a Paste into a Stray Character in the hosted program.
  avoid: key leak, fallthrough, unhandled shortcut
