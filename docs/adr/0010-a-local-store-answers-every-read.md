# A local store answers every read; sync is a background transport

Reads — launch, the history list, paging, Substitution matching — go to an
on-device SQLite database and never to a remote service. Cross-device sync
becomes a background reconciler that may be slow, offline or signed out with no
visible effect. The ubiquity container stops being a store and becomes one
replaceable transport among several.

## Context

The app kept its data as one JSON file per record inside the iCloud Drive
ubiquity container, and read it by scanning that directory at launch. The
measurements say the shape is not the defect, the container is:

- **4709 files**, 862 of them tombstones, **7.6 MB** total, average record 1626
  bytes. `du -sh` reports 0B — the files are dataless on disk.
- A full attribute scan of all 4709 on macOS, warm: **30 ms**.
- The same code, the same shape, on iOS: **16.3 seconds** inside
  `HistoryStoreFactory.make`, with `msToReady=17468` against `encoderMs=382`
  (see `vcdr-ios/docs/adr/0005-icloud-store-construction-off-the-main-actor.md`).

Three orders of magnitude between two platforms running identical code. The
directory walk is nearly free; what is not free is asking the iCloud daemon
4709 separate questions about dataless files. The record shape does not cause
that cost — it multiplies it.

That gives the rule this ADR records: **the launch path may ask iCloud about
one thing, or nothing, but never about N things.** The way to guarantee it is
not to ask on a read path at all.

## Decision

1. **The Local Store is the source of truth for reading.** One SQLite database
   per device holding both conversations and Substitutions — the app-group
   container on iOS (`group.glebglazov.vcdr-ios`), Application Support on
   macOS. Any read that can block on a remote service is a bug.

2. **The database file is never synced as a file.** SQLite with a WAL is
   several files mutating constantly; under iCloud file coordination a conflict
   resolves as a corrupted database, not a merge. Records sync; the database
   does not.

3. **`UbiquityHistoryStore` and `UbiquitySubstitutionStore` stop being stores.**
   One store per dataset over SQLite, plus a separate `SyncReconciler` that owns
   the container, the `NSMetadataQuery` watcher and the account state. The store
   must not know a transport exists. The `history.icloudSyncEnabled` toggle
   stops choosing an implementation and starts choosing whether the reconciler
   runs.

4. **The ubiquity container stays as the first transport.** Per-record JSON
   files, unchanged, reconciled in the background.

5. **`createdAt` and `lastUpdated` split.** `lastUpdated` is a merge clock and
   nothing else, and stops being rendered. `createdAt` — already written into
   every filename as `{createdAtISO}_{uuid}.json` — becomes a real column and is
   what the UI shows and what history sorts by. One field could not honestly be
   both: `FileSubstitutionStore` already nudges the stamp forward
   (`max(now, lastUpdated + resolution)`) to make a merge come out right, which
   falsifies a date the user reads.

6. **Migration keeps every file.** The Local Store is built from the container
   once, and every JSON file stays in place, untouched. Nothing is deleted by
   the change that introduces the new path.

7. **The Sync Window ships as a constant, not a number.** The reconciler reads
   its replication window from one place, and that place says "everything"
   today. It becomes a real bound when the transport is ours to bound.

## Considered options

- **A project-owned sync server.** The original stated preference, and the
  groundwork exists — `vcdr-server` is deployed with TLS, bearer-token auth and
  a QR pairing flow. Rejected for user data: it means paying to store the
  user's dictation history, and the Local Store removes the latency without
  anyone hosting anything.
- **CloudKit private database.** Delta sync by change token, nothing
  materializes, and storage counts against the user's own iCloud quota rather
  than the developer's. Not rejected — deferred. It is the next transport if
  the container proves insufficient *behind* the Local Store, and the Local
  Store is what makes that swap cheap.
- **`NSPersistentCloudKitContainer`.** Apple's own local-SQLite-mirrored-to-
  CloudKit, which is literally the shape decided here. Rejected: it trades a
  cost we can measure for a black box we cannot, and charges Core Data or
  SwiftData buy-in — every attribute optional, no unique constraints.
- **No sync at all**, per-device storage with explicit export/import. Kept as
  the honest floor. If measurement after this change shows history sync still
  costs more than it returns, history can take the floor and Substitutions —
  ten rows — would be no reason to keep a sync stack alive.

## Consequences

- **`vcdr-ios/docs/adr/0005` is completed, not contradicted.** It moved the
  blocking work off the main actor; this removes the blocking work from the
  launch path. Its warning stands: read `msToReady` against `encoderMs` before
  blaming the model.
- **The measurement that closes this is an iOS one.** macOS cannot show it at
  30 ms. Two numbers, cold launch, container in its normal evicted state: time
  to the history store being readable, and time to the record path being armed.
  Target: store readable under 100 ms, record path never waiting on it at all.
- **The old container files become dead weight eventually**, and removing them
  is a deliberate later change, made long after the new path is proven — never
  folded into the migration. Until then they are the rollback path, and they
  cost 7.6 MB.
- **Substitution merge behaviour changes at the same time**, see
  `0011-substitutions-converge-on-their-replacement.md`.
