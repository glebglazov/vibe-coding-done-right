import Foundation

/// Whether history syncs across devices, and how much of it a pass carries.
///
/// The user toggle defaults to ON and no longer chooses a store — the Local
/// Store answers every read either way. It chooses whether a
/// `SyncReconciler` runs for history: on, the device's records travel through
/// the iCloud container the OS replicates; off, they stay as files in the
/// app's own storage and nothing ever resolves the container.
nonisolated enum HistorySync {

    /// Persisted defaults key for the "Sync history via iCloud" toggle.
    static let syncEnabledDefaultsKey = "history.icloudSyncEnabled"

    /// Default when the user has not yet toggled the setting. Matches the
    /// `@AppStorage` default in the Settings UI so both agree on first launch.
    static let syncEnabledDefault = true

    /// How far back a reconcile pass reaches for changes.
    ///
    /// Unbounded, and one value so there is somewhere for a bound to go: the
    /// container is the OS's to replicate and it cannot be asked for less than
    /// all of it, so bounding the read here would only hide records the other
    /// device still shows. This becomes a real bound when the transport is
    /// ours to bound (see `docs/adr/0010`).
    static let replicationWindow: TimeInterval? = nil

    /// Where the device keeps its record files when it is not syncing through
    /// a container: the app's own storage, alongside the Local Store.
    static var localRecordFilesDirectory: URL {
        FileHistoryStore.localStorageRoot.appendingPathComponent("conversations")
    }

    /// History as the reconciler carries it.
    static var dataset: SyncedDataset {
        SyncedDataset(
            name: "History",
            containerSubdirectory: "conversations",
            localDirectory: localRecordFilesDirectory,
            syncEnabledDefaultsKey: syncEnabledDefaultsKey,
            syncEnabledDefault: syncEnabledDefault,
            resolveConflicts: HistoryConflictResolver.resolve(urls:)
        )
    }
}
