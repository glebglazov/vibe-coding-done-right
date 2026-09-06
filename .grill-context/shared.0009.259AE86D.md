---
fragment: 259AE86D
generation: 0009
branch: master
---

~ Local Store
  The on-device database every read answers from — the launch of the history list, its paging, matching a transcript against the Substitutions, and the Substitutions screen. One SQLite file holds conversations and Substitutions in tables of their own. It lives in the app's own storage — the app group on iOS, Application Support on macOS — and never in the ubiquity container, because a database cannot be synced as a file: iCloud file coordination resolves a conflict between its files as a corrupted database rather than a merge. Every build of the app on one device shares one Local Store, deliberately: its path carries no build configuration, so a Debug build and a Release build show the same history.
  was: The on-device database that answers every read — launch, the history list, paging, Substitution matching. It is the source of truth for reading, and no read may block on a remote service. It lives outside the ubiquity container, because a database file cannot be safely synced as a file.
  avoid: cache, local mirror, offline copy
  under: Local Storage and Sync

~ Replication Window
  How much of a Synced Dataset one Sync Pass reaches for. It is not a duration. The container is the OS's to replicate and cannot be asked for less than all of it, and a Record File's modification date is when the other device wrote it — so a clock cutoff would permanently skip a record that arrives late. The bound is per-file identity instead: a pass skips a file whose filename, modification date and size are the ones it already merged.
  was: How far back one reconcile pass reaches for changes. History's is unbounded today and stated in one place, because the container is the OS's to replicate and cannot be asked for less than all of it; it becomes a real bound when the transport is ours. Substitutions have none at all: a Substitution that arrives late puts visibly wrong text in the next transcript, where a history entry that arrives late costs nothing.
  avoid: sync horizon, sync window, page size, retention period
  under: Local Storage and Sync

- Sync Window
