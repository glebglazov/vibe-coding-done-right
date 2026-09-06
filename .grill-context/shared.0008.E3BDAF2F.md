---
fragment: E3BDAF2F
generation: 0008
branch: master
---

+ Container Watch
  The one query over the whole ubiquity container that every Synced Dataset hears its changes through. Exactly one exists, whatever the number of datasets: a query costs the same whether one dataset reads it or three, while a query per dataset makes every change wake all of them.
  avoid: metadata query, watcher, file observer
  under: Local Storage and Sync

+ Folder Route
  The rule that sends a change the Container Watch reports to the Synced Datasets whose folder holds it, and to no others. It tests folder containment rather than how a path begins, and it ignores the casing the filesystem hands back, because the volume folds case.
  avoid: path filter, prefix match, dataset filter
  under: Local Storage and Sync
