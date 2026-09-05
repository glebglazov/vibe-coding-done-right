---
fragment: 928C2FEF
generation: 0005
branch: master
---

+ Reachability Glow
  The keyboard's own rendering of In-Place Reachability: the record control is lit when the next tap records in place and dropped back when it will leave the keyboard for the app. It is the keyboard-side sibling of Mic Presence, reading the same predicate, so the two surfaces can never disagree about where a tap lands. It says only where the tap goes — never whether a model is ready, since an unready model still records.
  avoid: start button glow, halo, faint glow, readiness glow, lit pill
  under: Keyboard And App Reachability
