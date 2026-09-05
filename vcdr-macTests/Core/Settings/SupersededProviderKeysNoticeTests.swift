import Foundation
import Testing
@testable import vcdr_mac

@MainActor
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
}

@Suite("Superseded Provider key notice")
struct SupersededProviderKeysNoticeTests {

    @Test("No providers means no notice")
    func emptyIsNil() {
        #expect(SupersededProviderKeysNotice(providers: []) == nil)
    }

    @Test("One superseded provider is named on its own")
    func singleProviderMessage() throws {
        let notice = try #require(SupersededProviderKeysNotice(providers: [.anthropic]))
        #expect(notice.message.contains("Anthropic"))
        #expect(!notice.message.contains("OpenAI"))
    }

    @Test("Multiple superseded providers are all named")
    func multipleProvidersMessage() throws {
        let notice = try #require(SupersededProviderKeysNotice(providers: [.anthropic, .openai]))
        #expect(notice.message.contains("Anthropic"))
        #expect(notice.message.contains("OpenAI"))
    }
}

@Suite("Superseded Provider keys notice on the Providers screen")
@MainActor
struct SupersededProviderKeysScreenNoticeTests {

    @Test("A synced key that replaced a local one surfaces a notice naming the provider")
    func migrationSurfacesTheNotice() {
        let defaults = makeDefaults()
        defaults.set("sk-local", forKey: "ai_processing_anthropic_api_key")
        let store = InMemorySecretStore(secrets: ["ai_processing_anthropic_api_key": "sk-synced"])

        let settings = AppSettings(userDefaults: defaults, secretStore: store)

        #expect(settings.supersededProviderKeysNotice == SupersededProviderKeysNotice(providers: [.anthropic]))
    }

    @Test("A provider that migrated cleanly, or never had a key, raises no notice")
    func cleanMigrationRaisesNoNotice() {
        let defaults = makeDefaults()
        defaults.set("sk-existing", forKey: "ai_processing_anthropic_api_key")
        let settings = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())

        #expect(settings.supersededProviderKeysNotice == nil)
    }

    @Test("Acknowledging the notice clears it, and it does not return on the next launch")
    func acknowledgingClearsItForGood() {
        let defaults = makeDefaults()
        defaults.set("sk-local", forKey: "ai_processing_anthropic_api_key")
        let store = InMemorySecretStore(secrets: ["ai_processing_anthropic_api_key": "sk-synced"])
        let settings = AppSettings(userDefaults: defaults, secretStore: store)
        #expect(settings.supersededProviderKeysNotice != nil)

        settings.acknowledgeSupersededProviderKeysNotice()

        #expect(settings.supersededProviderKeysNotice == nil)
        #expect(AppSettings(userDefaults: defaults, secretStore: store).supersededProviderKeysNotice == nil)
    }
}
