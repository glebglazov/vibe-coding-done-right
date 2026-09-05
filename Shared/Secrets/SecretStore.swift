import Foundation

/// The single place every secret the app holds is written and read — one item per
/// secret, named by the same string that used to name its `UserDefaults` entry, so
/// the move off `UserDefaults` is one-to-one. See
/// `docs/adr/0009-secrets-live-in-a-synced-keychain-not-userdefaults.md`.
protocol SecretStore: Sendable {
    /// The stored secret, or `nil` when the Store holds no value for `key`.
    ///
    /// Throws rather than answering `nil` when the Store itself could not be read:
    /// a store that cannot answer is not a secret the user never set, and callers
    /// must be able to tell the two apart.
    nonisolated func secret(forKey key: String) throws -> String?

    /// Writes `secret` under `key`, replacing any value already there. A `nil`
    /// secret removes the item — the Store models "unset" as absence.
    nonisolated func setSecret(_ secret: String?, forKey key: String) throws
}

/// A Secret Store operation the underlying storage refused. The `status` is the
/// raw `SecItem*` result, kept for the log where the numeric code is what maps
/// to Apple's documentation.
enum SecretStoreError: Error {
    case readFailed(key: String, status: OSStatus)
    case writeFailed(key: String, status: OSStatus)
}
