import Foundation

/// A Local Store that converges with other devices by exchanging Record Files
/// in a directory.
///
/// A directory is all such a store is ever told. Whether it is an iCloud
/// container, and when it has changed, is `SyncReconciler`'s business — which
/// is what keeps every read off any remote service (see `docs/adr/0010`).
@MainActor
protocol RecordFileSyncedStore: AnyObject {
    /// Merges the directory's Record Files into the Local Store, writes out
    /// whatever the Local Store still owes it, and republishes what it holds.
    ///
    /// Called after the store is readable, never before: the merge reads every
    /// file in the directory.
    func syncRecordFiles(in directory: URL) async
}
