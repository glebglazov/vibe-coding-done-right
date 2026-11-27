import Foundation

/// OpenRouter adapter. OpenRouter serves many vendors' models behind one key and
/// speaks the OpenAI Chat Completions format, so the call is the OpenAI one sent
/// to OpenRouter's endpoint. Stays platform-agnostic (Foundation / URLSession
/// only — no AppKit/UIKit). Phase 1 keeps the default model ID hardcoded.
struct OpenRouterAdapter: LLMAdapter {
    let apiKey: String

    var displayName: String { CloudAIBackend.openrouter.displayName }

    private static let client = ChatCompletionsClient(
        backend: .openrouter,
        endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        model: "openai/gpt-4o-mini"
    )

    func process(text: String, systemPrompt: String) async throws -> String {
        try await Self.client.process(apiKey: apiKey, text: text, systemPrompt: systemPrompt)
    }
}
