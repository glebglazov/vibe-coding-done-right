import Foundation

/// Chooses between the local-only `FileHistoryStore` and the iCloud-backed
/// `UbiquityHistoryStore` at app launch based on user preference and
/// ubiquity-container availability.
///
/// The user toggle defaults to ON. When iCloud isn't available to the
/// process (entitlement missing, signed out, not yet provisioned),
/// `UbiquityHistoryStore()` returns nil and we fall back to the local
/// store — so the same binary runs in either mode without surfacing an
/// error. The toggle remains "on" cosmetically; sync simply resumes when
/// iCloud becomes available again.
@MainActor
enum HistoryStoreFactory {

    /// Persisted defaults key for the "Sync history via iCloud" toggle.
    static let syncEnabledDefaultsKey = "history.icloudSyncEnabled"

    /// Default when the user has not yet toggled the setting. Matches the
    /// `@AppStorage` default in Settings UI so the factory and the view
    /// agree on first launch.
    static let syncEnabledDefault = true

    /// - Parameter ubiquityRoot: the iCloud `Documents/VCDR` root, pre-resolved
    ///   off the main actor by the caller (nil if iCloud is unavailable). Taken
    ///   as a parameter rather than resolved here because the resolve blocks for
    ///   seconds, and `make` runs on the main actor — see `bootstrapHistory`.
    static func make(defaults: UserDefaults = .standard, ubiquityRoot: URL?) -> any HistoryStore {
        let syncEnabled = effectiveSyncEnabled(defaults: defaults)
        if syncEnabled, let ubiquityRoot, let store = UbiquityHistoryStore(storageRoot: ubiquityRoot) {
            return store
        }
        return FileHistoryStore()
    }

    /// Whether sync should be on given the current defaults. Returns
    /// `syncEnabledDefault` when the key is unset.
    static func effectiveSyncEnabled(defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: syncEnabledDefaultsKey) as? Bool) ?? syncEnabledDefault
    }
}
