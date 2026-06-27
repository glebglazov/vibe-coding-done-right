import Foundation
import Testing
@testable import vcdr_mac

@Suite("AIProviderFactory production wiring", .serialized)
struct AIProviderFactoryTests {
    @Test("factory assembles provider cascade from mode settings")
    @MainActor
    func factoryAssembly() {
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            promptType: .dictation
        )

        let provider = AIProviderFactory.make(
            for: mode,
            apiKey: "secret-key"
        )

        #expect(provider.primary is AnthropicAdapter)
        #expect(provider.fallback == nil)
        #expect(provider.maxAttempts == AIProviderFactory.cloudMaxAttempts)
        #expect(provider.timeout == AIProviderFactory.processingTimeout)
    }

    @Test("factory uses shared adapters for OpenAI and Gemini")
    @MainActor
    func sharedCloudAdaptersAreWired() {
        let openAIMode = Mode(
            id: UUID(),
            name: "OpenAI",
            processingType: .cloudAI,
            aiProvider: .openai,
            promptType: .dictation
        )
        let geminiMode = Mode(
            id: UUID(),
            name: "Gemini",
            processingType: .cloudAI,
            aiProvider: .gemini,
            promptType: .dictation
        )

        let openAI = AIProviderFactory.make(
            for: openAIMode,
            apiKey: "secret-key"
        )
        let gemini = AIProviderFactory.make(
            for: geminiMode,
            apiKey: "secret-key"
        )

        #expect(openAI.primary is OpenAIAdapter)
        #expect(gemini.primary is GeminiAdapter)
    }

    @Test("hung provider times out and pipeline substitutes local text")
    @MainActor
    func timeoutSubstitutesLocalText() async throws {
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            promptType: .dictation,
            appliesStyles: false
        )

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "Hello world",
            captures: [],
            aiAPIKey: "secret-key",
            aiPort: TimedOutAIProcessing(),
            style: .casual
        )

        #expect(result.text == "Hello world")
        #expect(result.hadExternalProcessing == false)
        #expect(result.aiProcessingFallback?.structuredText == "<dictation>Hello world</dictation>")
    }

    @Test("pipeline forwards the provider key (not a Variable) to the AI port")
    @MainActor
    func pipelineForwardsProviderKey() async throws {
        let mode = Mode(
            id: UUID(), name: "AI", processingType: .cloudAI,
            aiProvider: .anthropic, promptType: .dictation, appliesStyles: false
        )
        let capturing = KeyCapturingAIProcessing()

        _ = try await TextProcessingPipeline.run(
            mode: mode,
            text: "hi",
            captures: [],
            // A bash-only Variable value must never reach the AI call.
            variableEnvironment: ["ANTHROPIC_API_KEY": "bash-only"],
            aiAPIKey: "provider-key",
            aiPort: capturing,
            style: .casual
        )

        #expect(await capturing.receivedKey == "provider-key")
    }
}

private actor KeyCapturingAIProcessing: AIProcessingPort {
    private(set) var receivedKey: String?

    func process(
        structuredText: String,
        mode: Mode,
        apiKey: String,
        parameterValues: [String: String]
    ) async throws -> String {
        receivedKey = apiKey
        return "processed"
    }
}

private struct TimedOutAIProcessing: AIProcessingPort {
    func process(
        structuredText: String,
        mode: Mode,
        apiKey: String,
        parameterValues: [String: String]
    ) async throws -> String {
        throw ProviderCascade.AITimedOut()
    }
}
