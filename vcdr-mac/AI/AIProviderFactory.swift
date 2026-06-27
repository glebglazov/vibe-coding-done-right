import Foundation

/// Assembles the provider cascade for a macOS AI mode: primary adapter,
/// optional fallback, retry budget, and timeout.
enum AIProviderFactory {
    // MARK: - Constants

    /// Total primary-provider budget, including retries. A timed-out budget
    /// lets the caller substitute the local transcript.
    static let processingTimeout: Duration = .seconds(5)
    /// Cloud providers get bounded retries within the timeout budget.
    static let cloudMaxAttempts = 3
    /// On-device providers should not retry, if one is added later.
    static let onDeviceMaxAttempts = 1

    /// Builds the cascade for `mode`, using the AI Provider's stored API key directly.
    /// The key is the AI Provider's single source of truth — never resolved from a
    /// Variable. See `docs/adr/0001-ai-provider-key-source-of-truth.md`.
    static func make(
        for mode: Mode,
        apiKey: String
    ) -> ProviderCascade {
        let provider = mode.aiProvider
        let primary = provider.makeAdapter(apiKey: apiKey)

        return ProviderCascade(
            primary: primary,
            fallback: fallbackProvider(for: mode),
            maxAttempts: maxAttempts(for: provider),
            timeout: processingTimeout
        )
    }

    private static func fallbackProvider(
        for _: Mode
    ) -> (any LLMAdapter)? {
        nil
    }

    private static func maxAttempts(for provider: AIProvider) -> Int {
        switch provider {
        case .anthropic, .openai, .gemini:
            cloudMaxAttempts
        }
    }
}
