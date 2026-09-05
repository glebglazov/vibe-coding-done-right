import Foundation

/// Whether Substitutions sync across devices, and where their record files sit
/// when they do not.
///
/// The toggle defaults to ON and does not choose a store — the Local Store
/// answers matching and the Substitutions screen either way. It chooses
/// whether a `SyncReconciler` runs for Substitutions.
nonisolated enum SubstitutionSync {

    /// Persisted defaults key for the "Sync Substitutions via iCloud" toggle.
    static let syncEnabledDefaultsKey = "substitutions.icloudSyncEnabled"

    /// Persisted defaults key for the Substitutions' Last Sync Time.
    static let lastSyncTimeDefaultsKey = "substitutions.lastSyncTime"

    /// Default when the user has not yet toggled the setting.
    static let syncEnabledDefault = true

    /// Where the device keeps its Substitution record files when it is not
    /// syncing through a container: the app's own storage, alongside the Local
    /// Store, and the same folder the app has always used.
    static var localRecordFilesDirectory: URL {
        FileHistoryStore.localStorageRoot.appendingPathComponent(containerSubdirectory)
    }

    private static let containerSubdirectory = "Substitutions"

    /// Substitutions as the reconciler carries them.
    ///
    /// There is no replication window here, unlike history's: every pass reads
    /// the whole directory and applies what it finds at once. A Substitution
    /// that arrives late puts visibly wrong text in the next transcript, where
    /// a history entry that arrives late costs nothing — and the list is about
    /// ten entries, so eagerness is free.
    static var dataset: SyncedDataset {
        SyncedDataset(
            name: "Substitutions",
            containerSubdirectory: containerSubdirectory,
            localDirectory: localRecordFilesDirectory,
            syncEnabledDefaultsKey: syncEnabledDefaultsKey,
            syncEnabledDefault: syncEnabledDefault,
            lastSyncTimeDefaultsKey: lastSyncTimeDefaultsKey,
            resolveConflicts: SubstitutionConflictResolver.resolve(urls:)
        )
    }
}
