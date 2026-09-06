# A Substitution is named by its Replacement and read Trigger Phrases first

The Substitutions editors led with the Replacement on both platforms, on the recorded ground that the Replacement is "the thing the user meant" and the Trigger Phrases are "the ways the engine failed to write it". That ground is sound about *naming* and wrong about *reading*: a user meets a Substitution in the order he thinks about one, which is what was said and then what it becomes. Both rows and both editor forms now put the Trigger Phrases first and the Replacement second, and the Replacement keeps the prominence — a list row reads `"power zha", "powerja" → **Powierża**`, left to right, with the arrow saying the relation instead of leaving it to be inferred from stacking.

The distinction this records is that **naming is not ordering**. The Replacement still names the entry: it is the navigation title, it is the "New Substitution" empty state, it is what a list of thirty is scanned for, and it is what Substitution Convergence (ADR-0011) merges two devices' entries on. Only its position moved.

## Considered options

- **Move identity too** — make the Trigger Phrases what the entry *is*, retitle the detail screen from them, and retire the glossary's "named by its Replacement". Rejected: the reason given was about the order of reading and entry, which is a rendering claim; scanning a long list is a different act, and there the user hunts for the word he keeps having to fix. It would also leave Substitution Convergence merging on a field the user no longer thinks names the entry.
- **Stack the row with the weight inverted** — Trigger Phrases as the small grey line on top, Replacement bold below. Rejected: position and weight then disagree, and the eye lands on the bold line first — which is the thing the reordering exists to prevent.
- **Stack with the Trigger Phrases prominent** — coherent only under moving identity, and rejected with it.

## Consequences

- The caret lands on a blank Trigger Phrase row on every open, new entry or existing one, rather than on the Replacement. A visit that came to fix a Replacement pays one click. This is consistent over being clever: a rule that picks the field from the entry's state puts a Trigger Phrase into the Replacement field the first time it guesses wrong.
- That auto-appended row must not reach the store. `addPhrase()` mutates the entry, and the editors commit on any change, so an unguarded blank row would bump the Merge Clock and export a Record File merely because the screen was opened — and a look would then beat a real edit made on the other device. The blank row is suppressed from committing until it carries text.
- `Substitution.triggerSummary(losing:)` puts clashing Trigger Phrases first so a Trigger Phrase Clash mark cannot be truncated away. With the arrow row the Trigger Phrases are the side that truncates, so that reordering becomes more load-bearing, not less.
- This reverses the layout ADR-0007's editors shipped with, one release after they shipped. Recorded so the third reversal has to argue with the naming/ordering split rather than rediscover it.
