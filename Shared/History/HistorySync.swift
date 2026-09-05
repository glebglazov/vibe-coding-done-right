import Foundation

/// Whether history syncs across devices, and which directory of record files
/// it syncs through.
///
/// The user toggle defaults to ON and no longer chooses a store — the Local
/// Store answers every read either way. It chooses whether the records the
/// device writes travel: on, they land in the iCloud container the OS
/// replicates; off, they stay in the app's own storage.
///
/// When iCloud is not available to the process (entitlement missing, signed
/// out, not yet provisioned) the app's own storage stands in, so the same
/// binary runs in either mode without surfacing an error. The toggle stays
/// cosmetically "on" and syncing resumes when iCloud comes back.
nonisolated enum HistorySync {

    /// Persisted defaults key for the "Sync history via iCloud" toggle.
    static let syncEnabledDefaultsKey = "history.icloudSyncEnabled"

    /// Default when the user has not yet toggled the setting. Matches the
    /// `@AppStorage` default in the Settings UI so both agree on first launch.
    static let syncEnabledDefault = true

    /// Whether sync should be on given the current defaults. Returns
    /// `syncEnabledDefault` when the key is unset.
    static func effectiveSyncEnabled(defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: syncEnabledDefaultsKey) as? Bool) ?? syncEnabledDefault
    }

    /// The directory of per-record JSON files this device syncs through, with
    /// the toggle's own move (`HistoryMigrator`) already settled — flipping the
    /// setting relocates the files between iCloud and local storage.
    ///
    /// Blocking: resolving the ubiquity container provisions it, which takes
    /// seconds on the first launch after install. Callers must keep this off
    /// the cooperative pool and off any read path.
    static func prepareRecordFilesDirectory(syncEnabled: Bool) -> URL {
        let ubiquityRoot = syncEnabled ? UbiquityHistoryStore.resolveStorageRoot() : nil
        HistoryMigrator.reconcileAtLaunch(syncEnabled: syncEnabled, ubiquityRoot: ubiquityRoot)
        return (ubiquityRoot ?? FileHistoryStore.localStorageRoot)
            .appendingPathComponent("conversations")
    }
}
