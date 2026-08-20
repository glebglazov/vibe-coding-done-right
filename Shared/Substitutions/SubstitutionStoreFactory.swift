import Foundation

/// Chooses between the local-only `FileSubstitutionStore` and the iCloud-backed
/// `UbiquitySubstitutionStore` at app launch based on user preference and
/// ubiquity-container availability.
///
/// The user toggle defaults to ON. When iCloud isn't available to the
/// process (entitlement missing, signed out, not yet provisioned),
/// callers pass a nil `ubiquityRoot` and we fall back to the local
/// store — so the same binary runs in either mode without surfacing an
/// error. The toggle remains "on" cosmetically; sync simply resumes when
/// iCloud becomes available again.
@MainActor
enum SubstitutionStoreFactory {

    /// Persisted defaults key for the "Sync Substitutions via iCloud" toggle.
    static let syncEnabledDefaultsKey = "substitutions.icloudSyncEnabled"

    /// Default when the user has not yet toggled the setting.
    static let syncEnabledDefault = true

    /// Sendable payload produced off the main actor by `loadBootstrap`.
    /// `make(_:)` installs the concrete store from it without touching disk.
    struct Bootstrap: Sendable {
        enum Kind: Sendable {
            case ubiquity(UbiquitySubstitutionStore.Snapshot)
            case local(FileSubstitutionStore.Snapshot)
        }
        let kind: Kind
    }

    /// Loads the store snapshot off any thread. Callers must run this behind
    /// `withBlockingTask` (or equivalent GCD offload) — the scan, decode, and
    /// account-token read are blocking.
    ///
    /// - Parameter ubiquityRoot: the iCloud `Documents/VCDR` root, pre-resolved
    ///   off the main actor by the caller (nil if iCloud is unavailable).
    nonisolated static func loadBootstrap(
        syncEnabled: Bool,
        ubiquityRoot: URL?
    ) -> Bootstrap {
        if syncEnabled, let ubiquityRoot {
            return Bootstrap(kind: .ubiquity(UbiquitySubstitutionStore.loadSnapshot(storageRoot: ubiquityRoot)))
        }
        return Bootstrap(kind: .local(FileSubstitutionStore.loadSnapshot()))
    }

    /// Installs a store from a pre-loaded bootstrap. Cheap MainActor work only —
    /// no filesystem or iCloud calls.
    static func make(_ bootstrap: Bootstrap) -> any SubstitutionStore {
        switch bootstrap.kind {
        case .ubiquity(let snapshot):
            return UbiquitySubstitutionStore(snapshot: snapshot)
        case .local(let snapshot):
            return FileSubstitutionStore(snapshot: snapshot)
        }
    }

    /// Whether sync should be on given the current defaults. Returns
    /// `syncEnabledDefault` when the key is unset.
    static func effectiveSyncEnabled(defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: syncEnabledDefaultsKey) as? Bool) ?? syncEnabledDefault
    }
}
