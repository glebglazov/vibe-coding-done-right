# A Conversation has a status, and a Discarded Conversation syncs like any other

A Discard on iOS or on the Mac must never lose the user's words. So the discarded run's verbatim transcript is saved as a Conversation with the status `discarded`, which also records the output choices that were set when the run was discarded. The status is part of the Conversation record. It syncs with the record and stays until the user deletes the Conversation or processes it with AI.

## Decision

- **The status is one value with two cases**, `normal` and `discarded(RecordedOutputChoice)`. The Recorded Output Choice holds the platform, an opaque mode id, an optional opaque style id, and a label to show. The platform that wrote the ids owns them.
- **The record file carries the status under a top-level `"discarded"` key**: `{"platform", "mode", "style", "label"}`. A record without the key is normal, so every record written before this decision reads as normal and is written back unchanged.
- **An older build keeps the key and shows the entry as normal.** It stores the key in `extras` and writes it back verbatim, so no data is lost. It cannot process the entry with AI.
- **Processing a Discarded Conversation resolves it in place.** `resolveDiscarded` sets the output and the label, sets the status to normal, and moves `lastUpdated`. The id, the capture time and the record file name do not change, so the entry keeps its place in the list and every device merges the result as an edit.
- **Sync does not change.** The payload is the Conversation's JSON, and a merge is last-writer-wins on `lastUpdated` ([ADR-0010](0010-a-local-store-answers-every-read.md)). A Discarded Conversation is deleted with the same tombstone as any other.
- **The Local Store pages the Discarded filter in SQL.** A `discarded` column, filled from the record on every save and merge, lets History page only the discarded entries and count them, whatever pages are loaded. A database written before the column is given it on open, filled from the stored records.

## Considered options

- **A Boolean flag plus separate optional mode and style fields.** Rejected: it permits a normal entry with a stale recorded choice, and a discarded entry without one.
- **Filter the loaded pages in memory.** Rejected: the Discarded filter shows only what the pages already loaded, and the count is wrong.
- **Keep discarded runs on the device only.** Rejected: a run discarded on the phone must be processable later on the Mac, and the other way round.

## Consequences

- **A Conversation can have no output for a long time.** History screens must show a discarded entry as discarded and offer Process with AI.
- **A choice written by the other platform may not map.** The device that processes it uses its own current mode and style.
