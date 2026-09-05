---
fragment: 420C9A6B
generation: 0005
branch: master
---

+ Local Store
  The on-device database that answers every read — launch, the history list, paging, Substitution matching. It is the source of truth for reading, and no read may block on a remote service. It lives outside the ubiquity container, because a database file cannot be safely synced as a file.
  avoid: cache, local copy, offline store, mirror
  under: Sync

+ Sync Transport
  The background mechanism that moves records between a user's devices. It is replaceable — the ubiquity container, CloudKit, or nothing at all — because it never sits on a read path. It may be slow, offline or signed out with no visible effect.
  avoid: sync engine, backend, iCloud, sync layer

+ Sync Window
  The bounded set of recent records the Sync Transport replicates. Records outside it stay in the Local Store forever and are never deleted; they simply stop being copied between devices, so the sync cost stays flat while history grows.
  avoid: retention policy, pruning, archive, cap
