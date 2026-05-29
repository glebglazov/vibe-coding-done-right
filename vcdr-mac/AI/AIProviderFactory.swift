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

    static func make(
        for mode: Mode,
        variableEnvironment: [String: String]
    ) -> FallbackProvider {
        let provider = mode.aiProvider
        let apiKey = variableEnvironment[provider.apiKeyVariableName] ?? ""
        let primary = provider.makeProvider(apiKey: apiKey)

        return FallbackProvider(
            primary: primary,
            fallback: fallbackProvider(for: mode, variableEnvironment: variableEnvironment),
            maxAttempts: maxAttempts(for: provider),
            timeout: processingTimeout
        )
    }

    private static func fallbackProvider(
        for _: Mode,
        variableEnvironment _: [String: String]
    ) -> (any LLMProvider)? {
        nil
    }

    private static func maxAttempts(for provider: AIProvider) -> Int {
        switch provider {
        case .anthropic, .openai, .gemini:
            cloudMaxAttempts
        }
    }
}
