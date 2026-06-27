---
fragment: 25ced5b7
generation: 0001
branch: master
---

+ Substitution
  One entry in the iCloud-synced shared list that swaps a spoken phrase for fixed text in the raw transcript. A Substitution pairs a Trigger Phrase with a Replacement and applies on both macOS and iOS before any other text processing.
  avoid: Variable, Snippet, Macro, Shortcut, Alias, Expansion
  under: Substitutions

+ Trigger Phrase
  The spoken text that activates a Substitution when it appears in the transcript — e.g. "oh my zsh", "my personal email". Matched case-insensitively, on whole-word boundaries, longest-match-wins, left-to-right.
  avoid: keyword, alias, shortcut, variable name
  under: Substitutions

+ Replacement
  The fixed text a Substitution swaps in for its Trigger Phrase — e.g. an email address or URL. The Replacement is injected into the transcript before filler removal and is not itself re-scanned for further Trigger Phrases.
  avoid: value, expansion, alias target
  under: Substitutions
