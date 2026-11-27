import Foundation
import Testing
@testable import vcdr_ios

@Suite("iOS AI provider persistence", .serialized)
struct AIProviderTests {
    @Test("flat persisted values round-trip without migration", arguments: [
        "anthropic",
        "openai",
        "gemini",
        "openrouter",
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
        (AIProvider.gemini, "GeminiAdapter"),
        (AIProvider.openrouter, "OpenRouterAdapter")
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

/// Points the key seam at an in-memory Store holding these keys for the call. The account
/// names are spelled out rather than asked of `ProviderKeyStore`, so a change to the names
/// the two apps share shows up here as a failure instead of following along silently.
@MainActor
private func withAPIKeys(
    anthropic: String,
    openAI: String,
    gemini: String,
    operation: () -> Void
) {
    let original = ProviderKeyStore.current
    defer { ProviderKeyStore.current = original }
    ProviderKeyStore.current = ProviderKeyStore(
        secretStore: InMemorySecretStore(secrets: [
            "ai_processing_anthropic_api_key": anthropic,
            "ai_processing_openai_api_key": openAI,
            "ai_processing_gemini_api_key": gemini
        ]),
        userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
    )
    operation()
}
