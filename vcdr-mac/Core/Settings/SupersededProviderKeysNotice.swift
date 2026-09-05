import Foundation

/// The one-time notice shown on the Providers screen when the Secret Store migration
/// found a key already synced from another device that differed from this device's
/// local key. The synced key won; losing a working key silently is the one way that
/// migration could hurt someone, so it names every affected provider until acknowledged.
/// See `AppSettings.migrateProviderKeysToSecretStoreIfNeeded()`.
struct SupersededProviderKeysNotice: Equatable {
    let providers: [AIProvider]

    /// `nil` when no provider was superseded — nothing to show.
    init?(providers: [AIProvider]) {
        guard !providers.isEmpty else { return nil }
        self.providers = providers
    }

    /// The user-facing message naming every affected provider.
    var message: String {
        let names = providers.map(\.displayName).joined(separator: ", ")
        return providers.count == 1
            ? "A key synced from another device replaced this Mac's \(names) key."
            : "Keys synced from another device replaced this Mac's keys for: \(names)."
    }
}
