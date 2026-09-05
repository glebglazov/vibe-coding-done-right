# A Sync Pass is finished only when nothing is outstanding

The app now says when each Synced Dataset last synced, and a Sync Pass has two
candidate end points. The pass *returning* is cheap and already observable, but
it means only that the reconciler asked iCloud for the missing files —
`startDownloadingUbiquitousItem` does not wait for the bytes, which arrive over
the following minutes and drive further passes. On a cold launch against a
container of dataless Record Files that stamp would land a few hundred
milliseconds in and claim the device was current while the history list was
still visibly filling.

We record the Last Sync Time only for a **Settled Pass** — one that ended with
no Outstanding Work: nothing left undownloaded, no unresolved conflict, and no
row in the Local Store still owing a Record File.

## Consequences

`RecordFileSyncedStore.syncRecordFiles(in:)` no longer returns `Void`; it
returns what the pass left outstanding. This widens the store/reconciler
boundary that [ADR-0010](0010-a-local-store-answers-every-read.md) deliberately
kept to "a database and a directory", and it is widened on purpose: half of
Outstanding Work is the database's export flags, which the reconciler cannot
see by scanning the directory. The boundary still carries no iCloud concept in
either direction, so the substitution this ADR-0010 exists to permit is intact.

A dataset can also now stay unsettled indefinitely — one Record File the
container will never hand over is enough. The interface therefore separates
*working* (a pass is in flight) from *outstanding* (the last pass ended
unsettled): the second is a resting state that keeps showing the older, true
Last Sync Time rather than an indefinite spinner.
