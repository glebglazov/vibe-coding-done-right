# A Substitution's phrase list lands beside the singular key, not in place of it

Substitutions sync as one JSON file per entry through iCloud, decoded with synthesized `Codable` over four non-optional fields. Builds on different devices therefore read each other's files, and the decoder has two failure shapes that decide this migration. A build that meets a field it does not know **drops it on the next write** — the file is rewritten atomically with only the keys that build knows, and iCloud carries the erasure back. A build that meets a **missing** required field throws, and `FileSubstitutionStore`'s scan swallows the error with `try?`: the entry vanishes from that device with no log and nothing shown.

So new builds write `triggerPhrases` (the array) **and** keep writing `triggerPhrase`, set to the first phrase, purely as a landing pad for older readers. They decode `triggerPhrases` when present and fall back to `[triggerPhrase]` when it is absent. The worst mixed-version outcome becomes an old device truncating an entry to one phrase — visible, recoverable, and repaired the next time a new build writes the file — instead of the entry disappearing.

## Considered options

- **Rename `triggerPhrase` to `triggerPhrases`** — the clean shape. Rejected outright: it is precisely the missing-required-field case, so every device still on an older build silently loses every Substitution, with the loss invisible on both sides.
- **Ship a compatibility release first, then the feature** — teach every build to preserve unknown keys, wait, then add the array. Rejected as a guarantee that cannot be enforced: it only holds if every device installs the intermediate build, and nothing makes that true. Gating the feature on an unenforceable rollout buys confidence rather than safety.
- **Accept the loss and require every device on the new build** — rejected for the same reason, from the other end: it makes correctness depend on user behaviour that the app cannot observe.

## Consequences

- The singular key outlives its meaning. It is not a field, it is a tombstone for old readers, and it is dead weight the moment no device runs a pre-multi-phrase build; removing it is tracked as its own backlog item rather than left to be rediscovered.
- `Substitution` gains `schemaVersion` and an `extras` passthrough in the same change, copying the hand-written `init(from:)` that `Conversation` already uses to funnel unrecognised top-level keys through a round trip. That is what stops the *next* field needing a landing pad of its own, and it is the reason this is the last migration of this kind.
- Nothing about matching changes. The array is a container; each phrase competes in the same candidate pass under the rules already in force.
