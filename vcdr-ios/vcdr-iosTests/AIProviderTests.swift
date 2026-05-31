import Foundation
import Testing
@testable import vcdr_ios

@Suite("iOS AI provider persistence", .serialized)
struct AIProviderTests {
    @Test("flat persisted values round-trip without migration", arguments: [
        "anthropic",
        "openai",
        "gemini",
        "apple"
    ])
    func persistedValueRoundTrip(rawValue: String) throws {
        let provider = try #require(AIProvider(rawValue: rawValue))
        #expect(provider.rawValue == rawValue)

        let data = try JSONEncoder().encode(provider)
        #expect(try JSONDecoder().decode(AIProvider.self, from: data) == provider)
    }

    @Test("unknown persisted values are rejected")
    func rejectsUnknownValue() {
        #expect(AIProvider(rawValue: "unknown") == nil)
    }

    @Test("platform registration appends Apple only when AFM is available")
    @MainActor
    func appleRegistrationTracksAvailability() {
        withAPIKeys(anthropic: "a", openAI: "o", gemini: "g") {
            #expect(AIProvider.configuredProviders(isAFMAvailable: false) == [
                .anthropic, .openai, .gemini
            ])
            #expect(AIProvider.configuredProviders(isAFMAvailable: true) == [
                .anthropic, .openai, .gemini, .apple
            ])
        }
    }
}

@Suite("iOS AIProviderFactory wiring")
struct AIProviderFactoryTests {
    @Test("cloud primaries use shared adapters", arguments: [
        (AIProvider.anthropic, "AnthropicAdapter"),
        (AIProvider.openai, "OpenAIAdapter"),
        (AIProvider.gemini, "GeminiAdapter")
    ])
    func cloudPrimaryUsesSharedAdapter(provider: AIProvider, expectedType: String) {
        let cascade = AIProviderFactory.make(
            provider: provider,
            apiKey: "secret",
            afmFallbackEnabled: false,
            isAFMAvailable: false
        )

        #expect(String(describing: type(of: cascade.primary)) == expectedType)
        #expect(cascade.fallback == nil)
        #expect(cascade.maxAttempts == AIProviderFactory.cloudMaxAttempts)
        #expect(cascade.timeout == AIProviderFactory.processingTimeout)
    }

    @Test("Apple primary uses the iOS adapter and one attempt")
    func applePrimaryUsesPlatformAdapter() {
        let cascade = AIProviderFactory.make(
            provider: .apple,
            apiKey: "",
            afmFallbackEnabled: true,
            isAFMAvailable: true
        )

        #expect(cascade.primary is AppleAFMProvider)
        #expect(cascade.fallback == nil)
        #expect(cascade.maxAttempts == 1)
    }

    @Test("cloud primary gets Apple fallback only when enabled and available", arguments: [
        (true, true, true),
        (true, false, false),
        (false, true, false),
        (false, false, false)
    ])
    func appleFallbackPolicy(enabled: Bool, available: Bool, expectsFallback: Bool) {
        let cascade = AIProviderFactory.make(
            provider: .anthropic,
            apiKey: "secret",
            afmFallbackEnabled: enabled,
            isAFMAvailable: available
        )

        #expect((cascade.fallback is AppleAFMProvider) == expectsFallback)
    }
}

private func withAPIKeys(
    anthropic: String,
    openAI: String,
    gemini: String,
    operation: () -> Void
) {
    let defaults = UserDefaults.standard
    let keysAndValues = [
        AIProcessingSettings.anthropicApiKeyKey: anthropic,
        AIProcessingSettings.openaiApiKeyKey: openAI,
        AIProcessingSettings.geminiApiKeyKey: gemini
    ]
    let originals = keysAndValues.keys.map { key in
        (key, defaults.object(forKey: key))
    }
    defer {
        for (key, value) in originals {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
    for (key, value) in keysAndValues {
        defaults.set(value, forKey: key)
    }
    operation()
}
