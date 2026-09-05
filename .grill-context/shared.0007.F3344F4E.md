---
fragment: 5B2E9C41
generation: 0007
branch: master
---

+ Sync Pass
  One attempt to make a Synced Dataset's Local Store and its Record Files agree. A Sync Reconciler runs one whenever the directory stirs and whenever the user asks for one, and the passes of one dataset never overlap.
  avoid: sync cycle, refresh, reconcile run
  under: Local Storage and Sync

+ Outstanding Work
  Everything a Sync Pass ended without settling: a Record File whose bytes this device does not hold yet, a record two devices wrote at once that has not been collapsed, and a row in the Local Store that still owes its Record File. It is what separates a pass that finished from a device that agrees.
  under: Local Storage and Sync

+ Settled Pass
  A Sync Pass that ended with no Outstanding Work — the moment this device and the directory hold the same records. Only a Settled Pass moves the Last Sync Time, because asking iCloud for a file is not the same as having it.
  avoid: successful sync, completed pass
  under: Local Storage and Sync

+ Last Sync Time
  When a Synced Dataset last had a Settled Pass on this device. Each dataset keeps its own and survives a relaunch, so the app can say how current it is before it has had a chance to check.
  avoid: last updated, last refresh, sync date
  under: Local Storage and Sync
