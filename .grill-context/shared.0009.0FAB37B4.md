---
fragment: 0FAB37B4
generation: 0009
branch: master
---

~ Substitution
  One entry in the shared list that swaps spoken text for fixed text in the raw transcript. It holds one Replacement and any number of Trigger Phrases that produce it, and applies on both macOS and iOS before any other text processing. It is named by its Replacement — that is the thing the user meant — but it is read Trigger Phrases first, in the order the user thinks: what was said, then what it becomes.
  was: One entry in the shared list that swaps spoken text for fixed text in the raw transcript. It holds one Replacement and any number of Trigger Phrases that produce it, and applies on both macOS and iOS before any other text processing. It is identified to the user by its Replacement, because that is the thing the user meant; the Trigger Phrases are the ways the engine failed to write it.
  avoid: Variable, Snippet, Macro, Shortcut, Alias, Expansion, variant, mishearing entry
  under: Substitutions

~ Replacement
  The fixed text a Substitution swaps in for any of its Trigger Phrases — e.g. an email address or a correctly spelled name. There is exactly one per Substitution, and it is what names the Substitution wherever the user sees a list of them. Naming is not ordering: the Replacement is what the entry is called and what a list is scanned for, and it is still shown after the Trigger Phrases that produce it. The Replacement is injected into the transcript before filler removal and before AI processing, and is not itself re-scanned for further Trigger Phrases.
  was: The fixed text a Substitution swaps in for its Trigger Phrases — e.g. an email address or a correctly spelled name. There is exactly one per Substitution, and it is what names the Substitution wherever the user sees a list of them. The Replacement is injected into the transcript before filler removal and before AI processing, and is not itself re-scanned for further Trigger Phrases.
  avoid: value, expansion, alias target, correction
  under: Substitutions
