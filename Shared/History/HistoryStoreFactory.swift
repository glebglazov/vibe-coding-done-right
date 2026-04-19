import Foundation

/// Chooses between the local-only `FileHistoryStore` and the iCloud-backed
/// `UbiquityHistoryStore` at app launch based on user preference and account
/// availability.
///
/// Resolution order:
///   1. If the user has explicitly toggled the preference, that wins.
///   2. Otherwise, default to sync ON when iCloud is signed in, OFF otherwise.
///   3. If sync is desired but the ubiquity container is unavailable
///      (entitlement missing, not yet provisioned, account signed out),
///      fall back to the local store. This lets the same binary run in either
///      mode without runtime failure.
@MainActor
enum HistoryStoreFactory {

    /// Persisted defaults key for the "Sync history via iCloud" toggle.
    static let syncEnabledDefaultsKey = "history.icloudSyncEnabled"

    static func make(defaults: UserDefaults = .standard) -> any HistoryStore {
        let syncEnabled = effectiveSyncEnabled(defaults: defaults)
        if syncEnabled, let store = UbiquityHistoryStore() {
            return store
        }
        return FileHistoryStore()
    }

    /// Whether sync should be on given the current defaults + iCloud account
    /// state. Exposed for settings UI that wants to display the effective
    /// default when the toggle is unset.
    static func effectiveSyncEnabled(defaults: UserDefaults) -> Bool {
        if let explicit = defaults.object(forKey: syncEnabledDefaultsKey) as? Bool {
            return explicit
        }
        return defaultSyncEnabled()
    }

    /// Default for users who haven't toggled the setting: ON when iCloud is
    /// signed in, OFF otherwise. Probed via `ubiquityIdentityToken`, which is
    /// nil when the user is signed out of iCloud.
    private static func defaultSyncEnabled() -> Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }
}
