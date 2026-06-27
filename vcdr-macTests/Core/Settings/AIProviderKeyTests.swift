import Foundation
import Testing
@testable import vcdr_mac

@MainActor
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
}

@Suite("AI Provider key — single source of truth")
@MainActor
struct AIProviderKeyTests {

    // MARK: - Storage & resolution

    @Test("Setting and reading a provider key round-trips and persists")
    func keyPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(userDefaults: defaults)
        #expect(settings.apiKey(for: .anthropic).isEmpty)
        #expect(!settings.isProviderConfigured(.anthropic))

        settings.setAPIKey("sk-123", for: .anthropic)
        #expect(settings.apiKey(for: .anthropic) == "sk-123")
        #expect(settings.isProviderConfigured(.anthropic))

        // Reload from the same defaults — value survives.
        let reloaded = AppSettings(userDefaults: defaults)
        #expect(reloaded.apiKey(for: .anthropic) == "sk-123")
    }

    @Test("isModeConfigured reads the provider key, not a Variable")
    func modeConfiguredFromProvider() {
        let defaults = makeDefaults()
        let settings = AppSettings(userDefaults: defaults)
        let mode = Mode(
            id: UUID(), name: "AI", processingType: .cloudAI,
            aiProvider: .openai, promptType: .dictation
        )
        #expect(!settings.isModeConfigured(mode))

        // A Variable with the Reserved name must NOT configure the mode.
        settings.variables = [Variable(name: "OPENAI_API_KEY", value: "from-variable")]
        #expect(!settings.isModeConfigured(mode))

        settings.setAPIKey("from-provider", for: .openai)
        #expect(settings.isModeConfigured(mode))
    }

    // MARK: - Configured providers & Mode picker options

    @Test("configuredProviders lists only providers with a key, in allCases order")
    func configuredProvidersFiltersByKey() {
        let settings = AppSettings(userDefaults: makeDefaults())
        #expect(settings.configuredProviders.isEmpty)

        settings.setAPIKey("sk-gemini", for: .gemini)
        settings.setAPIKey("sk-anthropic", for: .anthropic)
        // OpenAI left unset.
        #expect(settings.configuredProviders == [.anthropic, .gemini])
    }

    @Test("Mode picker options keep a now-unconfigured selected provider visible")
    func pickerOptionsKeepUnconfiguredSelection() {
        let settings = AppSettings(userDefaults: makeDefaults())
        settings.setAPIKey("sk-openai", for: .openai)

        // Selected provider is unconfigured → still present (appended), no blank.
        let options = settings.providerPickerOptions(selected: .anthropic)
        #expect(options.contains(.anthropic))
        #expect(options == [.openai, .anthropic])

        // Selected provider is configured → not duplicated.
        let configuredSelection = settings.providerPickerOptions(selected: .openai)
        #expect(configuredSelection == [.openai])
    }

    // MARK: - Bash fallback & divergence

    @Test("Bash env falls back to the provider key under the Reserved name")
    func bashFallbackUsesProviderKey() {
        let settings = AppSettings(userDefaults: makeDefaults())
        settings.setAPIKey("sk-anthropic", for: .anthropic)
        #expect(settings.variableEnvironment["ANTHROPIC_API_KEY"] == "sk-anthropic")
    }

    @Test("Non-empty Reserved Variable overrides only the bash value, never the AI key")
    func reservedOverrideIsBashOnly() {
        let settings = AppSettings(userDefaults: makeDefaults())
        settings.setAPIKey("sk-provider", for: .anthropic)
        settings.variables = [Variable(name: "ANTHROPIC_API_KEY", value: "sk-bash-override")]

        // Bash sees the override...
        #expect(settings.variableEnvironment["ANTHROPIC_API_KEY"] == "sk-bash-override")
        // ...but the AI-call key stays the provider key.
        #expect(settings.apiKey(for: .anthropic) == "sk-provider")
    }

    @Test("Empty Reserved Variable falls back to the provider key for bash")
    func emptyReservedFallsBack() {
        let settings = AppSettings(userDefaults: makeDefaults())
        settings.setAPIKey("sk-provider", for: .anthropic)
        settings.variables = [Variable(name: "ANTHROPIC_API_KEY", value: "")]
        #expect(settings.variableEnvironment["ANTHROPIC_API_KEY"] == "sk-provider")
    }

    // MARK: - Migration

    @Test("Reserved Variable rows are no longer auto-created")
    func noAutoCreatedReservedRows() {
        let settings = AppSettings(userDefaults: makeDefaults())
        #expect(settings.variables.isEmpty)
    }

    @Test("Migration moves a non-empty Reserved Variable into the empty Provider key and drops the row")
    func migrationSeedsEmptyProviderKey() throws {
        let defaults = makeDefaults()
        let legacy = [
            Variable(name: "ANTHROPIC_API_KEY", value: "sk-legacy"),
            Variable(name: "OPENAI_API_KEY", value: ""),
            Variable(name: "MY_VAR", value: "keep-me"),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "variables")

        let settings = AppSettings(userDefaults: defaults)
        // Legacy key folded into the provider key.
        #expect(settings.apiKey(for: .anthropic) == "sk-legacy")
        // Reserved rows removed (incl. the empty one); user var kept.
        #expect(settings.variables.map(\.name) == ["MY_VAR"])

        // Migration persisted and does not re-run on reload.
        let reloaded = AppSettings(userDefaults: defaults)
        #expect(reloaded.apiKey(for: .anthropic) == "sk-legacy")
        #expect(reloaded.variables.map(\.name) == ["MY_VAR"])
    }

    @Test("Migration leaves both untouched when a Provider key and a non-empty Reserved Variable coexist")
    func migrationLeavesBothWhenProviderKeySet() throws {
        let defaults = makeDefaults()
        defaults.set("sk-provider", forKey: "ai_processing_anthropic_api_key")
        let legacy = [Variable(name: "ANTHROPIC_API_KEY", value: "sk-variable")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "variables")

        let settings = AppSettings(userDefaults: defaults)
        #expect(settings.apiKey(for: .anthropic) == "sk-provider")
        #expect(settings.variables.contains { $0.name == "ANTHROPIC_API_KEY" && $0.value == "sk-variable" })
    }

    @Test("Migration runs once — a Reserved Variable added afterwards is not consumed")
    func migrationRunsOnce() throws {
        let defaults = makeDefaults()
        let legacy = [Variable(name: "GOOGLE_API_KEY", value: "sk-gemini")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "variables")

        let settings = AppSettings(userDefaults: defaults)
        #expect(settings.apiKey(for: .gemini) == "sk-gemini")
        #expect(!settings.variables.contains { $0.name == "GOOGLE_API_KEY" })

        // User adds an explicit Reserved override later; the flag is set, so no re-migration.
        settings.variables.append(Variable(name: "GOOGLE_API_KEY", value: "later-override"))
        let reloaded = AppSettings(userDefaults: defaults)
        #expect(reloaded.variables.contains { $0.name == "GOOGLE_API_KEY" && $0.value == "later-override" })
        // The provider key is unchanged by the new variable (AI key stays authoritative).
        #expect(reloaded.apiKey(for: .gemini) == "sk-gemini")
    }
}
