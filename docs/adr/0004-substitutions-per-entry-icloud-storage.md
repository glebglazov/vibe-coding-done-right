# Substitutions sync as per-entry files in the ubiquity container

Substitutions (Trigger Phrase → Replacement, applied to the raw transcript before any other text processing on both platforms) sync as **one file per Substitution** in the existing iCloud Drive ubiquity container (`iCloud.glebglazov.vcdr`, `Documents/VCDR/Substitutions/<id>.json`), reusing the history storage layer: `FileHistoryStore`-style I/O, `HistoryConflictResolver` LWW on `lastUpdated`, and a `SubstitutionTombstone` (delete wins when `deletedAt > lastUpdated`). The matching engine lives in `Shared/` so macOS and iOS share one matcher.

## Considered options

- **`NSUbiquitousKeyValueStore`** — Apple's blessed path for synced settings. Rejected: introduces a second iCloud mechanism plus a new `kvstore` entitlement, and its per-key merge advantage only materializes if each Substitution is its own key — the same granularity choice we can make with files, using the sync stack we already trust.
- **Single JSON blob for the whole list** (file or KVS) — simplest. Rejected: LWW on the entire list means two devices editing *different* Substitutions in one sync window lose one side's edits. Per-entry granularity confines LWW to the rare same-entry concurrent edit.
- **Plain file deletion, no tombstones** — Rejected: an offline peer still holding an entry can resurrect it on reconnect, and delete-vs-edit has no deterministic winner. Tombstones mirror the established history pattern for a small marginal cost.

## Consequences

- Per-entry granularity: concurrent edits to different Substitutions both survive; only a same-entry concurrent edit hits LWW (last writer wins).
- No new entitlement and one sync mental model for the whole app, since history already uses this exact machinery.
- The iOS keyboard extension never touches the Substitutions store — substitution runs in the app pipeline and the keyboard receives already-substituted `Bundled Result` text.
