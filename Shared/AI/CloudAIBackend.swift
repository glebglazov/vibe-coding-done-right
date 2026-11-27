import Foundation

/// The shared backend identity for the HTTP cloud providers. This is the
/// `Cloud AI Backend` of the LLM Adapter Seam — it covers Anthropic, OpenAI,
/// Gemini and OpenRouter only. Platform-only backends (Apple AFM on iOS, a future macOS local
/// agent) are **not** members here: each platform registers those separately
/// through Platform Backend Registration so they never leak into a shared
/// `CaseIterable` picker.
///
/// macOS will alias its `AIProvider` to this in slice 2
/// (`typealias AIProvider = CloudAIBackend`); iOS wraps it in a `.cloud(_)` case.
enum CloudAIBackend: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openai
    case gemini
    case openrouter

    /// Human-readable name for logs / UI.
    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        }
    }

    /// The environment / settings variable name that holds this backend's API key.
    var apiKeyVariableName: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OPENAI_API_KEY"
        case .gemini: "GOOGLE_API_KEY"
        case .openrouter: "OPENROUTER_API_KEY"
        }
    }

    /// Builds the concrete cloud adapter for this backend. Adapters own their
    /// own request shape, response decode, and missing-key validation. This is
    /// the cloud adapter factory convenience the PRD places on Cloud AI Backend —
    /// platform AI Provider Selection calls it once it has resolved the key.
    func makeAdapter(apiKey: String) -> any LLMAdapter {
        switch self {
        case .anthropic: AnthropicAdapter(apiKey: apiKey)
        case .openai: OpenAIAdapter(apiKey: apiKey)
        case .gemini: GeminiAdapter(apiKey: apiKey)
        case .openrouter: OpenRouterAdapter(apiKey: apiKey)
        }
    }
}
