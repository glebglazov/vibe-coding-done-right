import Foundation

/// Chooses between the local-only `FileSubstitutionStore` and the iCloud-backed
/// `UbiquitySubstitutionStore` at app launch based on user preference and
/// ubiquity-container availability.
///
/// The user toggle defaults to ON. When iCloud isn't available to the process
/// (entitlement missing, signed out, not yet provisioned),
/// `UbiquitySubstitutionStore()` returns nil and we fall back to the local
/// store — so the same binary runs in either mode without surfacing an error.
/// Sync resumes when iCloud becomes available again.
@MainActor
enum SubstitutionStoreFactory {

    /// Persisted defaults key for the "Sync Substitutions via iCloud" toggle.
    static let syncEnabledDefaultsKey = "substitutions.icloudSyncEnabled"

    /// Default when the user has not yet toggled the setting.
    static let syncEnabledDefault = true

    /// - Parameter ubiquityRoot: the iCloud `Documents/VCDR` root, pre-resolved
    ///   off the main actor by the caller (nil if iCloud is unavailable). Taken
    ///   as a parameter rather than resolved here because the resolve can block
    ///   for seconds, and `make` runs on the main actor.
    static func make(defaults: UserDefaults = .standard, ubiquityRoot: URL?) -> any SubstitutionStore {
        let syncEnabled = effectiveSyncEnabled(defaults: defaults)
        if syncEnabled, let ubiquityRoot, let store = UbiquitySubstitutionStore(storageRoot: ubiquityRoot) {
            return store
        }
        return FileSubstitutionStore()
    }

    /// Whether sync should be on given the current defaults. Returns
    /// `syncEnabledDefault` when the key is unset.
    static func effectiveSyncEnabled(defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: syncEnabledDefaultsKey) as? Bool) ?? syncEnabledDefault
    }
}
