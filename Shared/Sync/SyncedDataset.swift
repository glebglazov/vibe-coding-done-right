import Foundation

/// What the `SyncReconciler` has to know about one dataset: which toggle turns
/// its sync on, which folder of the container its Record Files occupy, and
/// where those files live when the device syncs through no container at all.
///
/// Conversations and Substitutions travel between devices the same way and
/// differ only in these answers, so one reconciler carries either.
nonisolated struct SyncedDataset: Sendable {

    /// Names the dataset in the reconciler's log lines.
    let name: String

    /// The folder its Record Files occupy: under the container's
    /// `Documents/VCDR` when it syncs through one, and in the app's own
    /// storage when it does not.
    let folder: RecordFilesFolder

    let syncEnabledDefaultsKey: String
    let syncEnabledDefault: Bool

    /// Persisted key for this dataset's Last Sync Time. Each dataset keeps its
    /// own, so a device can be current on Substitutions and behind on history.
    let lastSyncTimeDefaultsKey: String

    /// Collapses the `NSFileVersion` siblings two devices produced for one
    /// record onto a single winner. The rule is the dataset's own — the
    /// records at these URLs are only decodable by whoever knows their shape.
    let resolveConflicts: @Sendable ([URL]) -> Void

    /// Whether sync should be on given the current defaults. Returns
    /// `syncEnabledDefault` when the key is unset.
    func syncEnabled(defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: syncEnabledDefaultsKey) as? Bool) ?? syncEnabledDefault
    }

    /// When this dataset last had a Settled Pass on this device, or nil if it
    /// never has. Read at launch, before any pass has had a chance to run.
    func lastSyncTime(defaults: UserDefaults) -> Date? {
        defaults.object(forKey: lastSyncTimeDefaultsKey) as? Date
    }

    func recordLastSyncTime(_ time: Date, defaults: UserDefaults) {
        defaults.set(time, forKey: lastSyncTimeDefaultsKey)
    }
}
