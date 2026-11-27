import Foundation

/// OpenAI Chat Completions API adapter. Stays platform-agnostic (Foundation /
/// URLSession only — no AppKit/UIKit). Phase 1 keeps the default model ID
/// hardcoded.
struct OpenAIAdapter: LLMAdapter {
    let apiKey: String

    var displayName: String { CloudAIBackend.openai.displayName }

    private static let client = ChatCompletionsClient(
        backend: .openai,
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: "gpt-4o-mini"
    )

    func process(text: String, systemPrompt: String) async throws -> String {
        try await Self.client.process(apiKey: apiKey, text: text, systemPrompt: systemPrompt)
    }
}
