import Foundation

/// Assembles the `FallbackProvider` for a given mode from the persisted AI
/// settings: the primary adapter, an optional on-device AFM fallback, and the
/// retry/timeout budget. Owns the budget constants that used to sit on the
/// coordinator.
enum AIProviderFactory {
    /// Time budget for the primary AI provider (including retries).
    static let processingTimeout: Duration = .seconds(5)
    /// Maximum retry attempts for cloud providers within the timeout budget.
    static let maxRetries = 3

    @MainActor
    static func make(for mode: AIPromptMode) -> FallbackProvider {
        let provider = AIProcessingSettings.provider(for: mode)
        let apiKey = AIProcessingSettings.apiKey(for: provider)
        let primary = provider.makeProvider(apiKey: apiKey)

        // AFM fallback only when a cloud provider is primary, the fallback is
        // enabled for this mode, and AFM is actually available on-device —
        // matching the prior `provider != .apple` cascade rule.
        let fallback: (any LLMProvider)?
        if provider != .apple,
           AIProcessingSettings.afmFallbackEnabled(for: mode),
           AIProcessingSettings.isAFMAvailable {
            fallback = AppleAFMProvider()
        } else {
            fallback = nil
        }

        // Cloud providers retry within the budget; Apple gets a single attempt.
        let maxAttempts = provider.requiresAPIKey ? maxRetries : 1

        return FallbackProvider(
            primary: primary,
            fallback: fallback,
            maxAttempts: maxAttempts,
            timeout: processingTimeout
        )
    }
}
