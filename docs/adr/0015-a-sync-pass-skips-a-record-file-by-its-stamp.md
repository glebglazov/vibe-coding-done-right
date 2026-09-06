# A Sync Pass skips a Record File by its stamp, never by a clock

Every Sync Pass currently reads and decodes every Record File in the directory —
4,738 of them for history today. The bound that stops it is not a date cutoff.
It is a per-file stamp: the filename, its modification date and its size,
remembered from the pass that merged it. A file whose stamp is unchanged is
skipped without being opened.

## Context

`HistorySync.replicationWindow` is `nil`, so `HistoryImporter.merge` passes a nil
cutoff to `ConversationFileArchive.scan(modifiedAfter:)`, nothing is filtered,
and every file gets a `Data(contentsOf:)` and a `JSONDecoder`.

**The nil is correct and must stay.** A Record File's modification date is when
the *other* device wrote it, and iCloud replicates that date along with the
content. A conversation dictated on the phone last week that finishes arriving
today still carries last week's date. Any clock-based cutoff would therefore skip
it — not once, but permanently, because the date never moves again. The comment
at `Shared/History/HistorySync.swift:24-28` says this, and this ADR is what stops
the nil from being read as an unfinished bound and "fixed".

## Decision

Key the skip on the file's identity, not on time. The Local Store remembers
`(filename, modificationDate, size)` for every Record File it has merged, and a
pass skips any file whose triple is unchanged. This is correct regardless of when
a file arrives, because arriving does not change a file's stamp.

## Consequences

- **The expensive part is exactly what is skipped.** ADR-0010 measured a full
  attribute scan of 4,709 files on macOS at 30 ms. The cost is not the directory
  walk; it is asking the iCloud daemon for the *content* of a dataless file. A
  stamp match avoids that question entirely.
- **The scan gets the size for free.** `scan` already reads
  `.contentModificationDateKey` for every file. Adding `.fileSizeKey` to the same
  `includingPropertiesForKeys` costs nothing more.
- **Deletions are still caught.** The pass lists the whole directory, so a
  filename the store knows and the directory no longer holds is gone. That is a
  set difference, with no decode. Tombstones need rows of their own.
- **The stamp table is the durable truth; the Container Watch notification is a
  fast path.** `NSMetadataQueryDidUpdate` carries `kMDQueryUpdateAddedItems`,
  `ChangedItems` and `RemovedItems`, and acting on them lets a pass touch one
  file instead of all of them. It is an optimisation on top, not a replacement:
  it says nothing about an app that was shut for a month. Both exist, and the
  stamp table is what a pass may not skip.
- **`Replication Window` stops meaning a duration for this transport.** The
  container is the OS's to replicate and cannot be asked for less than all of it,
  so the only bound available is per-file identity.
