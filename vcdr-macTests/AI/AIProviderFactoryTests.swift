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
            variableEnvironment: ["ANTHROPIC_API_KEY": "secret-key"]
        )

        #expect(provider.primary is AnthropicAdapter)
        #expect(provider.fallback == nil)
        #expect(provider.maxAttempts == AIProviderFactory.cloudMaxAttempts)
        #expect(provider.timeout == AIProviderFactory.processingTimeout)
    }

    @Test("factory keeps OpenAI and Gemini on their platform-local adapters")
    @MainActor
    func localCloudAdaptersRemainWired() {
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
            variableEnvironment: ["OPENAI_API_KEY": "secret-key"]
        )
        let gemini = AIProviderFactory.make(
            for: geminiMode,
            variableEnvironment: ["GOOGLE_API_KEY": "secret-key"]
        )

        #expect(openAI.primary is OpenAIProvider)
        #expect(gemini.primary is GeminiProvider)
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
            variableEnvironment: ["ANTHROPIC_API_KEY": "secret-key"],
            aiPort: TimedOutAIProcessing(),
            style: .casual
        )

        #expect(result.text == "Hello world")
        #expect(result.hadExternalProcessing == false)
        #expect(result.aiProcessingFallback?.structuredText == "<dictation>Hello world</dictation>")
    }
}

private struct TimedOutAIProcessing: AIProcessingPort {
    func process(
        structuredText: String,
        mode: Mode,
        variableEnvironment: [String: String],
        parameterValues: [String: String]
    ) async throws -> String {
        throw ProviderCascade.AITimedOut()
    }
}
