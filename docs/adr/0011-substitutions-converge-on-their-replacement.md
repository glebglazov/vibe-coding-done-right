# Substitutions converge on their Replacement, and a deleted phrase stays deleted

Two Substitutions with an identical Replacement are one Substitution that two
devices happened to create separately. They merge: the older id survives, the
loser gets a tombstone, and the Trigger Phrases combine. Phrases carry their own
add and remove stamps so a delete beats a stale add.

## Context

`Substitution` is identified in code by a `UUID`, and the Shared glossary
already says it "is identified to the user by its Replacement, because that is
the thing the user meant." The two disagree, and offline editing shows where.

Add `gleb@example.com` on the Mac with the phrase "gleb at gmail", add the same
Replacement on the phone with "glep at gmail", both offline. Two ids, one
Replacement. Today that lands as two Substitutions in a permanent Trigger Phrase
Clash rather than the one entry with two phrases the user obviously meant.

Naive set union is not the fix. A phrase deleted on one device returns the
moment a peer that never saw the delete syncs its older copy — union always
resurrects. And keying purely on Replacement text splits an entry the moment
someone fixes a typo in it.

## Decision

1. **Identical Replacement, different ids: converge.** The **older id
   survives**, so both devices reach the same answer with no coordination. The
   loser gets a `SubstitutionTombstone`, as any other delete would.

2. **Trigger Phrases carry their own stamps.** A phrase is no longer a bare
   string in an array but a phrase with an added-at and an optional removed-at,
   and delete wins — the same shape ADR-0004 already chose for records. Nothing
   resurrects.

3. **The id beats the key when both are present.** The Replacement key merges
   strangers only; it never splits an entry that already has an identity. Editing
   a Replacement keeps the id.

4. **History keeps plain last-writer-wins.** A Conversation is written once and
   barely changes — only `label` is really editable. Concurrent same-record
   edits are close to hypothetical, and merge machinery built for a case that
   never happens is machinery that is never right.

## Consequences

- **`0004-substitutions-per-entry-icloud-storage.md` is amended, not replaced.**
  Per-entry granularity and tombstones survive intact; only the merge rule for
  two entries sharing a Replacement changes.
- **Trigger Phrase Clash narrows to what it was always for**: two *different*
  Replacements claiming one phrase, which is a real ambiguity a user must see.
  Two entries with the *same* Replacement stop reaching the user as a clash,
  because they were never a conflict — they were one entry.
- **`ADR-0008`'s singular `triggerPhrase` landing pad still has to encode.** Old
  builds read one phrase from a key that now summarises a stamped set.
