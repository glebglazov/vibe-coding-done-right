import Testing
@testable import vcdr_ios

/// Covers the `AIProvider → LLMProvider` factory mapping and the cloud adapters'
/// missing-key guard. Network calls themselves stay manual / on-device.
@Suite("LLMProvider factory + adapters")
struct LLMProviderTests {

    // MARK: - Factory mapping

    @Test("factory maps .anthropic to AnthropicProvider with matching displayName")
    func factoryAnthropic() {
        let provider = AIProvider.anthropic.makeProvider(apiKey: "key")
        #expect(provider is AnthropicProvider)
        #expect(provider.displayName == AIProvider.anthropic.displayName)
    }

    @Test("factory maps .openai to OpenAIProvider with matching displayName")
    func factoryOpenAI() {
        let provider = AIProvider.openai.makeProvider(apiKey: "key")
        #expect(provider is OpenAIProvider)
        #expect(provider.displayName == AIProvider.openai.displayName)
    }

    @Test("factory maps .gemini to GeminiProvider with matching displayName")
    func factoryGemini() {
        let provider = AIProvider.gemini.makeProvider(apiKey: "key")
        #expect(provider is GeminiProvider)
        #expect(provider.displayName == AIProvider.gemini.displayName)
    }

    @Test("factory maps .apple to AppleAFMProvider with matching displayName")
    func factoryApple() {
        let provider = AIProvider.apple.makeProvider(apiKey: "")
        #expect(provider is AppleAFMProvider)
        #expect(provider.displayName == AIProvider.apple.displayName)
    }

    // MARK: - Missing-key guard (cloud adapters)

    @Test("Anthropic adapter throws on empty API key")
    func anthropicMissingKey() async {
        let provider = AnthropicProvider(apiKey: "")
        await #expect(throws: AIClientError.self) {
            _ = try await provider.process(text: "hello", systemPrompt: "system")
        }
    }

    @Test("OpenAI adapter throws on empty API key")
    func openAIMissingKey() async {
        let provider = OpenAIProvider(apiKey: "")
        await #expect(throws: AIClientError.self) {
            _ = try await provider.process(text: "hello", systemPrompt: "system")
        }
    }

    @Test("Gemini adapter throws on empty API key")
    func geminiMissingKey() async {
        let provider = GeminiProvider(apiKey: "")
        await #expect(throws: AIClientError.self) {
            _ = try await provider.process(text: "hello", systemPrompt: "system")
        }
    }

    // MARK: - Fake adapter sanity

    @Test("FakeLLMProvider returns scripted output and counts attempts")
    func fakeProvider() async throws {
        let fake = FakeLLMProvider(behavior: .alwaysSucceed(output: "ok"))
        let out = try await fake.process(text: "x", systemPrompt: "y")
        #expect(out == "ok")
        #expect(fake.attempts == 1)
    }
}
