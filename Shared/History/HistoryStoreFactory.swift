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

    static func make(defaults: UserDefaults = .standard) -> any HistoryStore {
        let syncEnabled = effectiveSyncEnabled(defaults: defaults)
        if syncEnabled, let store = UbiquityHistoryStore() {
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
