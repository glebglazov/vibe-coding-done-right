import Foundation
import OSLog

/// The cloud Providers' API keys as the app reads them. The Secret Store owns the keys;
/// this mirrors what it held at launch so reads stay synchronous and observable, and
/// every write goes through to the Store. Mirrors the macOS app's provider keys on
/// `AppSettings` — same item names, same shared access group, so a key pasted on the Mac
/// arrives here. See `docs/adr/0009-secrets-live-in-a-synced-keychain-not-userdefaults.md`.
@MainActor
@Observable
final class ProviderKeyStore {
    /// The instance the settings seam reads. The suites replace it with one over an
    /// in-memory Store, so no test reaches the device keychain.
    static var current = ProviderKeyStore(secretStore: KeychainSecretStore())

    /// Persisted flag gating the one-shot Provider key → Secret Store migration.
    private static let didMigrateKey = "didMigrateProviderKeysToSecretStore"

    private let secretStore: any SecretStore
    private let userDefaults: UserDefaults
    private var keys: [CloudAIBackend: String] = [:]

    init(secretStore: any SecretStore, userDefaults: UserDefaults = .standard) {
        self.secretStore = secretStore
        self.userDefaults = userDefaults

        var unreadable = false
        for backend in CloudAIBackend.allCases {
            do {
                keys[backend] = try secretStore.secret(forKey: Self.storageKey(for: backend)) ?? ""
            } catch {
                keys[backend] = ""
                unreadable = true
                Logger.ai.error("Secret Store read failed for \(backend.displayName): \(error)")
            }
        }

        migrateKeysToSecretStoreIfNeeded(storeIsReadable: !unreadable)
    }

    /// The stored API key for a cloud backend (empty string if unset).
    func key(for backend: CloudAIBackend) -> String {
        keys[backend] ?? ""
    }

    /// Stores a backend's API key — the single source of truth AI calls read. A refused
    /// write leaves the mirrored key in place, so the session the user pasted it in keeps
    /// working.
    func setKey(_ key: String, for backend: CloudAIBackend) {
        keys[backend] = key
        do {
            try secretStore.setSecret(key, forKey: Self.storageKey(for: backend))
        } catch {
            Logger.ai.error("Secret Store write failed for \(backend.displayName): \(error)")
        }
    }

    /// The name a backend's key is stored under: its Secret Store item, and the
    /// `UserDefaults` entry the one-shot migration drains into that item. The strings are
    /// the macOS app's too — a synced item only matches a query with the same account.
    private static func storageKey(for backend: CloudAIBackend) -> String {
        switch backend {
        case .anthropic: "ai_processing_anthropic_api_key"
        case .openai: "ai_processing_openai_api_key"
        case .gemini: "ai_processing_gemini_api_key"
        }
    }

    /// One-shot migration of each Provider key out of `UserDefaults` and into the Secret
    /// Store, gated by a persisted flag. A key is copied only where the Store holds nothing
    /// for that backend; where the Store already holds a differing key — one synced from
    /// another device — the stored key wins. The `UserDefaults` entry goes either way:
    /// nothing secret stays there.
    private func migrateKeysToSecretStoreIfNeeded(storeIsReadable: Bool) {
        guard !userDefaults.bool(forKey: Self.didMigrateKey) else { return }
        // A Store that would not answer is indistinguishable from an empty one, and acting
        // on that guess would overwrite a synced key. Leave everything and retry next launch.
        guard storeIsReadable else { return }

        for backend in CloudAIBackend.allCases {
            let storageKey = Self.storageKey(for: backend)
            let carried = userDefaults.string(forKey: storageKey) ?? ""
            if !carried.isEmpty {
                if key(for: backend).isEmpty {
                    do {
                        try secretStore.setSecret(carried, forKey: storageKey)
                    } catch {
                        // Dropping the entry now would lose the key. Abandon the run with
                        // the flag unset; the backends already migrated stay migrated.
                        Logger.ai.error("Secret Store migration failed for \(backend.displayName): \(error)")
                        return
                    }
                    keys[backend] = carried
                } else {
                    Logger.ai.notice("\(backend.displayName) key superseded by the one synced from another device")
                }
            }
            userDefaults.removeObject(forKey: storageKey)
        }

        userDefaults.set(true, forKey: Self.didMigrateKey)
        Logger.ai.info("Provider keys migrated to the Secret Store")
    }
}
