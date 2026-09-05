import Foundation
import Testing
@testable import vcdr_mac

@MainActor
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
}

/// The account name the Variables list is filed under, in both stores.
private let variablesName = "variables"

private func encoded(_ variables: [Variable]) throws -> String {
    String(data: try JSONEncoder().encode(variables), encoding: .utf8)!
}

/// The list the Store's single item holds, read the way the app reads it.
private func storedList(in store: InMemorySecretStore) throws -> [Variable] {
    let secret = try #require(try store.secret(forKey: variablesName))
    return try JSONDecoder().decode([Variable].self, from: Data(secret.utf8))
}

@Suite("The Variables list lives in the Secret Store")
@MainActor
struct VariablesSecretStoreTests {

    // MARK: - Storage

    @Test("An edited list lands in the Store as one item and nothing lands in UserDefaults")
    func listGoesToTheStore() throws {
        let defaults = makeDefaults()
        let store = InMemorySecretStore()
        let settings = AppSettings(userDefaults: defaults, secretStore: store)

        settings.variables = [Variable(name: "MY_VAR", value: "secret")]

        #expect(try storedList(in: store) == settings.variables)
        #expect(defaults.object(forKey: variablesName) == nil)
        let reloaded = AppSettings(userDefaults: defaults, secretStore: store)
        #expect(reloaded.variables == settings.variables)
    }

    @Test("The environment handed to bash scripts is the list the Store holds")
    func environmentComesFromTheStore() throws {
        let store = InMemorySecretStore(
            secrets: [variablesName: try encoded([Variable(name: "MY_VAR", value: "from-store")])]
        )
        let settings = AppSettings(userDefaults: makeDefaults(), secretStore: store)

        #expect(settings.variableEnvironment["MY_VAR"] == "from-store")
        #expect(settings.definedVariableNames.contains("MY_VAR"))
    }

    // MARK: - Migration

    @Test("An existing install's list moves into the empty Store and leaves UserDefaults")
    func migrationMovesTheList() throws {
        let defaults = makeDefaults()
        let existing = [Variable(name: "MY_VAR", value: "keep-me")]
        defaults.set(try JSONEncoder().encode(existing), forKey: variablesName)
        let store = InMemorySecretStore()

        let settings = AppSettings(userDefaults: defaults, secretStore: store)

        #expect(settings.variables == existing)
        #expect(try storedList(in: store) == existing)
        #expect(defaults.object(forKey: variablesName) == nil)

        // Runs once: a list written back into UserDefaults afterwards is left alone.
        defaults.set(try JSONEncoder().encode([Variable(name: "LATER", value: "x")]), forKey: variablesName)
        let reloaded = AppSettings(userDefaults: defaults, secretStore: store)
        #expect(reloaded.variables == existing)
        #expect(defaults.object(forKey: variablesName) != nil)
    }

    @Test("A list already synced from another device wins over the local one")
    func syncedListWins() throws {
        let defaults = makeDefaults()
        defaults.set(try JSONEncoder().encode([Variable(name: "LOCAL", value: "local")]), forKey: variablesName)
        let synced = [Variable(name: "SYNCED", value: "synced")]
        let store = InMemorySecretStore(secrets: [variablesName: try encoded(synced)])

        let settings = AppSettings(userDefaults: defaults, secretStore: store)

        #expect(settings.variables == synced)
        #expect(defaults.object(forKey: variablesName) == nil)
    }

    @Test("A Store that cannot be read defers the migration instead of guessing it is empty")
    func unreadableStoreDefersMigration() throws {
        let defaults = makeDefaults()
        defaults.set(try JSONEncoder().encode([Variable(name: "MY_VAR", value: "keep-me")]), forKey: variablesName)
        let store = InMemorySecretStore()
        store.failRead(forKey: variablesName)

        _ = AppSettings(userDefaults: defaults, secretStore: store)

        #expect(defaults.object(forKey: variablesName) != nil)
    }
}
