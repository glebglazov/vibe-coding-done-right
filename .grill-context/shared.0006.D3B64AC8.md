---
fragment: D3B64AC8
generation: 0006
branch: master
---

~ Substitution
  One entry in the shared list that swaps spoken text for fixed text in the raw transcript. It holds one Replacement and any number of Trigger Phrases that produce it, and applies on both macOS and iOS before any other text processing. It is identified to the user by its Replacement, because that is the thing the user meant; the Trigger Phrases are the ways the engine failed to write it.
  was: One entry in the iCloud-synced shared list that swaps spoken text for fixed text in the raw transcript. A Substitution holds one Replacement and any number of Trigger Phrases that produce it, and applies on both macOS and iOS before any other text processing. It is identified to the user by its Replacement, because that is the thing the user meant; the Trigger Phrases are the ways the engine failed to write it.
  avoid: Variable, Snippet, Macro, Shortcut, Alias, Expansion, variant, mishearing entry
  under: Substitutions

~ Trigger Phrase
  One of the spoken texts that activates a Substitution when it appears in the transcript. A Substitution has one or more; they are an unordered set, carry no precedence between them, and each carries its own add and remove stamp so a delete beats a stale add from a device that never saw it. Matched case-insensitively, on whole-word boundaries, longest-match-wins, left-to-right.
  was: One of the spoken texts that activates a Substitution when it appears in the transcript — e.g. "oh my zsh", or any of the shapes the engine returns for a name it cannot spell. A Substitution has one or more; they are an unordered set, carry no precedence between them, and are added one at a time as each is discovered. Matched case-insensitively, on whole-word boundaries, longest-match-wins, left-to-right.
  avoid: keyword, alias, shortcut, variable name, variant, form, spelling, heard-as
  under: Substitutions

+ Substitution Convergence
  Two Substitutions holding an identical Replacement are one Substitution that two devices created separately, and they merge into it: the older id survives and the Trigger Phrases combine. It is not a Trigger Phrase Clash — a clash is two different Replacements competing for one phrase, which a user must see and settle.
  avoid: dedupe, merge conflict, collision, duplicate entry
  under: Substitutions

+ Merge Clock
  The stamp a record carries so two devices can agree which edit is later. It is the writing device's wall clock, it may be nudged to keep a delete ahead of the edit it buries, and it is never shown to the user — a date a user reads must be true, and this one answers to the merge instead.
  avoid: lastUpdated, timestamp, modified date, last synced
  under: Sync

+ Capture Time
  When the user actually said the thing. It is what the history list shows and sorts by, it never moves after the record is written, and it is separate from the Merge Clock precisely because that one does move.
  avoid: created date, timestamp, lastUpdated
  under: Sync
