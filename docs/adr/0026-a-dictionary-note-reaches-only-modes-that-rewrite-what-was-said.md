# A Dictionary Note reaches only modes that rewrite what was said

Accepted. Amends [ADR-0025](0025-the-dictionary-holds-spelling-hints-beside-substitutions.md) and [ADR-0011](0011-substitutions-converge-on-their-replacement.md).

A Spelling Hint gives the LLM a spelling, but not which entry a misheard word meant. "Katelyn" and "Caitlin" sound the same; only the user knows that one is their dentist and the other a colleague. So a Dictionary Entry can hold a **Note**: what the entry is, in the user's words. The Note goes with its spelling into the `<spelling_hints>` block of a Dictation prompt only: a macOS Mode whose prompt type is Dictation, and the iOS Dictation AI Prompt Mode. Assistant and Custom prompts get the spellings alone, as before. A Transcription Model never gets a Note.

The rule follows what the LLM does with the text. In Dictation it rewrites what the user said and adds nothing of its own, so a Note can only help it choose a spelling. In Assistant it writes new text, and it uses a Note as material: an email request gets signed "Gleb" because that Note says "my own name", and "book a dentist appointment" gets "Katelyn" because her Note says "my dentist". The eval in [`evals/dictionary_notes/REPORT.md`](../../evals/dictionary_notes/REPORT.md) measured both:

| Mode | Hit rate, spellings → Notes | False insertions, spellings → Notes |
|---|---|---|
| Dictation | +10 to +14 points | +0.5 to +2.5 points, inside the spread |
| Assistant | +22 to +24 points | 3% → 23% (Haiku), 7% → 33% (Gemini) |

A wrong name added to an email the user sends is worse than a misspelled name they can see, so Assistant gives up the gain.

## Considered options

- **Notes in every LLM prompt.** Rejected: the Assistant false insertions above.
- **Notes everywhere, with a guard sentence in the block intro** against sign-offs and topic matches. Rejected: the eval tested it as arm D, and it changed nothing measurable in any cell.
- **A per-Mode toggle.** Rejected: the prompt type already says whether a mode rewrites or writes, and a toggle is one more synced setting to explain. It can come later if a Custom prompt that only cleans up text needs Notes.

## Consequences

- A Custom prompt gets spellings only. The app cannot know what a custom prompt asks the LLM to do, and spellings only is the safe side.
- Assistant fixes a misheard name less often than it could: 58% to 71% of the time, against 82% to 93% with Notes.
- A Note is personal data, and in Dictation it goes to the cloud LLM provider with every request. The Dictionary screen says so.
- In Dictation, a Note can pull a near-sound toward an entry: Gemini wrote "Gleb" for every spoken "Glen" with Notes, and 4 times in 9 without. This is accepted. Run the eval again when the block changes.
- Substitution Convergence keeps a Note. The surviving entry keeps its own Note; if it has none, it takes the Note of the most recently edited loser that has one. Without this, a Note that only the loser had would be deleted with it.
- An older build keeps the Note as an unknown key and writes it back (ADR-0008). If that build changes the Replacement, the Note can describe the old one. This happens only while two builds share a Dictionary, and needs no fix.
- The block intro sentence does not change, so the spellings-only block stays byte-identical to the one before Notes.
