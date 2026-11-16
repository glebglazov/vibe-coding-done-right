import Foundation
import Testing
@testable import vcdr_mac

@MainActor
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
}

/// The account name the Anthropic key is filed under, in both stores.
private let anthropicKeyName = "ai_processing_anthropic_api_key"

@Suite("AI Provider keys live in the Secret Store")
@MainActor
struct ProviderKeySecretStoreTests {

    // MARK: - Storage

    @Test("A pasted key lands in the Secret Store and nothing lands in UserDefaults")
    func keyGoesToTheStore() throws {
        let defaults = makeDefaults()
        let store = InMemorySecretStore()
        let settings = AppSettings(userDefaults: defaults, secretStore: store)

        settings.setAPIKey("sk-pasted", for: .anthropic)

        #expect(try store.secret(forKey: anthropicKeyName) == "sk-pasted")
        #expect(defaults.string(forKey: anthropicKeyName) == nil)
        #expect(AppSettings(userDefaults: defaults, secretStore: store).apiKey(for: .anthropic) == "sk-pasted")
    }

    @Test("Clearing a key removes it from the Store")
    func clearingRemovesTheSecret() throws {
        let store = InMemorySecretStore()
        let settings = AppSettings(userDefaults: makeDefaults(), secretStore: store)
        settings.setAPIKey("sk-pasted", for: .anthropic)

        settings.setAPIKey("", for: .anthropic)

        #expect(try store.secret(forKey: anthropicKeyName) == nil)
        #expect(!settings.isProviderConfigured(.anthropic))
    }

    // MARK: - Migration

    @Test("An existing install's key moves into the empty Store and leaves UserDefaults")
    func migrationMovesTheKey() throws {
        let defaults = makeDefaults()
        defaults.set("sk-existing", forKey: anthropicKeyName)
        let store = InMemorySecretStore()

        let settings = AppSettings(userDefaults: defaults, secretStore: store)

        #expect(settings.apiKey(for: .anthropic) == "sk-existing")
        #expect(try store.secret(forKey: anthropicKeyName) == "sk-existing")
        #expect(defaults.string(forKey: anthropicKeyName) == nil)
        #expect(settings.providersWithSupersededKeys.isEmpty)

        // Runs once: a value written back into UserDefaults afterwards is left alone.
        defaults.set("sk-later", forKey: anthropicKeyName)
        let reloaded = AppSettings(userDefaults: defaults, secretStore: store)
        #expect(reloaded.apiKey(for: .anthropic) == "sk-existing")
        #expect(defaults.string(forKey: anthropicKeyName) == "sk-later")
    }

    @Test("A key already synced from another device wins, and the provider is recorded")
    func syncedKeyWinsAndIsRecorded() throws {
        let defaults = makeDefaults()
        defaults.set("sk-local", forKey: anthropicKeyName)
        defaults.set("sk-openai-local", forKey: "ai_processing_openai_api_key")
        let store = InMemorySecretStore(secrets: [anthropicKeyName: "sk-synced"])

        let settings = AppSettings(userDefaults: defaults, secretStore: store)

        #expect(settings.apiKey(for: .anthropic) == "sk-synced")
        #expect(defaults.string(forKey: anthropicKeyName) == nil)
        // Only the provider whose key was replaced — not the one that migrated cleanly.
        #expect(settings.providersWithSupersededKeys == [.anthropic])
        #expect(settings.apiKey(for: .openai) == "sk-openai-local")

        // The record survives the launch that made it, for the Providers screen to read.
        #expect(AppSettings(userDefaults: defaults, secretStore: store).providersWithSupersededKeys == [.anthropic])
    }

    @Test("A Store that cannot be read defers the migration instead of guessing it is empty")
    func unreadableStoreDefersMigration() {
        let defaults = makeDefaults()
        defaults.set("sk-local", forKey: anthropicKeyName)
        let store = InMemorySecretStore()
        store.failRead(forKey: anthropicKeyName)

        _ = AppSettings(userDefaults: defaults, secretStore: store)

        #expect(defaults.string(forKey: anthropicKeyName) == "sk-local")
    }

    // MARK: - A failed read is not an unset key

    @Test("An unreadable key fails the AI call with its own error, not the missing-key one")
    func unreadableKeyRaisesItsOwnError() async throws {
        let store = InMemorySecretStore(secrets: [anthropicKeyName: "sk-stored"])
        store.failRead(forKey: anthropicKeyName)
        let settings = AppSettings(userDefaults: makeDefaults(), secretStore: store)
        let mode = Mode(
            id: UUID(), name: "AI", processingType: .cloudAI,
            aiProvider: .anthropic, promptType: .dictation
        )

        // The mode stays usable — hiding it would present the failed read as an unset key.
        #expect(settings.isModeConfigured(mode))

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "hello",
            aiAPIKey: settings.storedAPIKey(for: .anthropic),
            aiPort: UnreachableAIProcessing(),
            style: .casual
        )

        let message = try #require(result.aiProcessingFallback?.errorMessage)
        #expect(message == CloudAIClientError.secretStoreUnreadable(provider: .anthropic).errorDescription)
        #expect(message != CloudAIClientError.missingAPIKey(provider: .anthropic).errorDescription)
    }
}

/// AI port for the unreadable-key path: the call must never get this far.
private struct UnreachableAIProcessing: AIProcessingPort {
    func process(
        structuredText: String,
        mode: Mode,
        spellingHints: SpellingHints,
        apiKey: String,
        parameterValues: [String: String]
    ) async throws -> String {
        Issue.record("AI call was made with an unreadable key")
        return structuredText
    }
}
