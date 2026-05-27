import Foundation

/// One non-streaming text-enhancement call. Adapters wrap a concrete backend
/// (HTTP provider or on-device model). Mirrors the HistoryStore /
/// TranscriptionProvider existential-protocol pattern so the AI path gains a
/// real seam (three adapters today) and can be exercised with a fake.
protocol LLMProvider: Sendable {
    /// Human-readable name for logs / UI. Mirrors `AIProvider.displayName`.
    var displayName: String { get }
    func process(text: String, systemPrompt: String) async throws -> String
}

extension AIProvider {
    /// Builds the concrete adapter for this provider. Cloud adapters carry the
    /// API key and surface `missingAPIKey` from their own `process`.
    func makeProvider(apiKey: String) -> any LLMProvider {
        switch self {
        case .anthropic: AnthropicProvider(apiKey: apiKey)
        case .openai: OpenAIProvider(apiKey: apiKey)
        case .gemini: GeminiProvider(apiKey: apiKey)
        case .apple: AppleAFMProvider()
        }
    }
}
