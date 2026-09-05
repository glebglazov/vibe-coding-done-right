import Foundation
import Security

/// The Secret Store the app ships: generic-password keychain items, synchronizable
/// so a key pasted on one device reaches the others, in an access group both the
/// macOS and iOS apps carry.
struct KeychainSecretStore: SecretStore {
    // MARK: - Constants

    /// The service every item is filed under. Deliberately *not* either app's
    /// bundle id: a synced item only matches a query whose service is identical,
    /// and the two apps' bundle ids differ (`glebglazov.vcdr-mac`,
    /// `glebglazov.vcdr-ios`).
    private static let service = "glebglazov.vcdr"

    /// The access group both apps are entitled to. Their default groups are derived
    /// from their differing bundle ids and would never see each other's items.
    /// Matches `keychain-access-groups` in each app's entitlements, with
    /// `$(AppIdentifierPrefix)` resolved to the team id.
    private static let accessGroup = "R9G7S83AGV.glebglazov.vcdr.keys"

    nonisolated func secret(forKey key: String) throws -> String? {
        var query = Self.itemQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.readFailed(key: key, status: status)
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.readFailed(key: key, status: status)
        }
    }

    nonisolated func setSecret(_ secret: String?, forKey key: String) throws {
        guard let secret, !secret.isEmpty else {
            let status = SecItemDelete(Self.itemQuery(forKey: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.writeFailed(key: key, status: status)
            }
            return
        }

        let data = Data(secret.utf8)
        let update = SecItemUpdate(
            Self.itemQuery(forKey: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw SecretStoreError.writeFailed(key: key, status: update)
        }

        var item = Self.itemQuery(forKey: key)
        item[kSecValueData as String] = data
        // A synchronizable item cannot use a `ThisDeviceOnly` class; after-first-unlock
        // is the strongest one left, and lets a background AI call read the key on a
        // device the user has not touched since boot.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw SecretStoreError.writeFailed(key: key, status: add)
        }
    }

    /// The attributes that identify one secret's item. `kSecUseDataProtectionKeychain`
    /// is on every call because the legacy file-based login keychain does not sync —
    /// items written there are stranded on the device that wrote them.
    private static func itemQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
