import Foundation
import Testing
@testable import vcdr_ios

@MainActor
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
}

/// The account name the Anthropic key is filed under, in both stores.
private let anthropicKeyName = "ai_processing_anthropic_api_key"

@Suite("iOS Provider keys live in the Secret Store")
@MainActor
struct ProviderKeyStoreTests {

    @Test("A pasted key lands in the Secret Store and nothing lands in UserDefaults")
    func keyGoesToTheStore() throws {
        let defaults = makeDefaults()
        let secrets = InMemorySecretStore()
        let keys = ProviderKeyStore(secretStore: secrets, userDefaults: defaults)

        keys.setKey("sk-pasted", for: .anthropic)

        #expect(try secrets.secret(forKey: anthropicKeyName) == "sk-pasted")
        #expect(defaults.string(forKey: anthropicKeyName) == nil)
        #expect(ProviderKeyStore(secretStore: secrets, userDefaults: defaults).key(for: .anthropic) == "sk-pasted")
    }

    @Test("Clearing a key removes it from the Store and unconfigures the provider")
    func clearingRemovesTheSecret() throws {
        let secrets = InMemorySecretStore()
        let keys = ProviderKeyStore(secretStore: secrets, userDefaults: makeDefaults())
        keys.setKey("sk-pasted", for: .anthropic)

        keys.setKey("", for: .anthropic)

        #expect(try secrets.secret(forKey: anthropicKeyName) == nil)
        #expect(keys.key(for: .anthropic).isEmpty)
    }

    @Test("An existing install's key moves into the empty Store and leaves UserDefaults")
    func migrationMovesTheKey() throws {
        let defaults = makeDefaults()
        defaults.set("sk-existing", forKey: anthropicKeyName)
        let secrets = InMemorySecretStore()

        let keys = ProviderKeyStore(secretStore: secrets, userDefaults: defaults)

        #expect(keys.key(for: .anthropic) == "sk-existing")
        #expect(try secrets.secret(forKey: anthropicKeyName) == "sk-existing")
        #expect(defaults.string(forKey: anthropicKeyName) == nil)

        // Runs once: a value written back into UserDefaults afterwards is left alone.
        defaults.set("sk-later", forKey: anthropicKeyName)
        let reloaded = ProviderKeyStore(secretStore: secrets, userDefaults: defaults)
        #expect(reloaded.key(for: .anthropic) == "sk-existing")
        #expect(defaults.string(forKey: anthropicKeyName) == "sk-later")
    }

    @Test("A key already synced from another device wins over the local one")
    func syncedKeyWins() throws {
        let defaults = makeDefaults()
        defaults.set("sk-local", forKey: anthropicKeyName)
        defaults.set("sk-openai-local", forKey: "ai_processing_openai_api_key")
        let secrets = InMemorySecretStore(secrets: [anthropicKeyName: "sk-synced"])

        let keys = ProviderKeyStore(secretStore: secrets, userDefaults: defaults)

        #expect(keys.key(for: .anthropic) == "sk-synced")
        #expect(defaults.string(forKey: anthropicKeyName) == nil)
        #expect(keys.key(for: .openai) == "sk-openai-local")
    }

    @Test("A Store that cannot be read defers the migration instead of guessing it is empty")
    func unreadableStoreDefersMigration() {
        let defaults = makeDefaults()
        defaults.set("sk-local", forKey: anthropicKeyName)
        let secrets = InMemorySecretStore()
        secrets.failRead(forKey: anthropicKeyName)

        _ = ProviderKeyStore(secretStore: secrets, userDefaults: defaults)

        #expect(defaults.string(forKey: anthropicKeyName) == "sk-local")
    }
}
