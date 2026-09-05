---
fragment: F498724D
generation: 0003
branch: master
---

~ Substitution
  One entry in the iCloud-synced shared list that swaps spoken text for fixed text in the raw transcript. A Substitution holds one Replacement and any number of Trigger Phrases that produce it, and applies on both macOS and iOS before any other text processing. It is identified to the user by its Replacement, because that is the thing the user meant; the Trigger Phrases are the ways the engine failed to write it.
  was: One entry in the iCloud-synced shared list that swaps a spoken phrase for fixed text in the raw transcript. A Substitution pairs a Trigger Phrase with a Replacement and applies on both macOS and iOS before any other text processing.
  avoid: Variable, Snippet, Macro, Shortcut, Alias, Expansion, variant, mishearing entry
  under: Substitutions

~ Trigger Phrase
  One of the spoken texts that activates a Substitution when it appears in the transcript — e.g. "oh my zsh", or any of the shapes the engine returns for a name it cannot spell. A Substitution has one or more; they are an unordered set, carry no precedence between them, and are added one at a time as each is discovered. Matched case-insensitively, on whole-word boundaries, longest-match-wins, left-to-right.
  was: The spoken text that activates a Substitution when it appears in the transcript — e.g. "oh my zsh", "my personal email". Matched case-insensitively, on whole-word boundaries, longest-match-wins, left-to-right.
  avoid: keyword, alias, shortcut, variable name, variant, form, spelling, heard-as
  under: Substitutions

~ Replacement
  The fixed text a Substitution swaps in for any of its Trigger Phrases — e.g. an email address or a correctly spelled name. There is exactly one per Substitution, and it is what names the Substitution wherever the user sees a list of them. The Replacement is injected into the transcript before filler removal and before AI processing, and is not itself re-scanned for further Trigger Phrases.
  was: The fixed text a Substitution swaps in for its Trigger Phrase — e.g. an email address or URL. The Replacement is injected into the transcript before filler removal and is not itself re-scanned for further Trigger Phrases.
  avoid: value, expansion, alias target, correction
  under: Substitutions

+ Trigger Phrase Clash
  Two Substitutions claiming the same Trigger Phrase. It is never refused — refusing lands on the user at the moment he is filing a phrase he just discovered, which is the moment the feature exists to serve. The most recently edited Substitution wins, and the losing phrase says so where it was typed rather than announcing that something somewhere is wrong.
  avoid: duplicate trigger, conflict, collision, ambiguous match
  under: Substitutions
