import Foundation

/// Assembles the `ProviderCascade` for a given mode from the persisted AI
/// settings: the primary adapter, an optional on-device AFM fallback, and the
/// retry/timeout budget. Owns the budget constants that used to sit on the
/// coordinator.
enum AIProviderFactory {
    /// Time budget for the primary AI provider (including retries).
    static let processingTimeout: Duration = .seconds(5)
    /// Maximum retry attempts for cloud providers within the timeout budget.
    static let cloudMaxAttempts = 3

    @MainActor
    static func make(for mode: AIPromptMode) -> ProviderCascade {
        let provider = AIProcessingSettings.provider(for: mode)
        return make(
            provider: provider,
            apiKey: AIProcessingSettings.apiKey(for: provider),
            afmFallbackEnabled: AIProcessingSettings.afmFallbackEnabled(for: mode),
            isAFMAvailable: AIProcessingSettings.isAFMAvailable
        )
    }

    static func make(
        provider: AIProvider,
        apiKey: String,
        afmFallbackEnabled: Bool,
        isAFMAvailable: Bool
    ) -> ProviderCascade {
        let primary = provider.makeAdapter(apiKey: apiKey)

        // AFM fallback only when a cloud provider is primary, the fallback is
        // enabled for this mode, and AFM is actually available on-device —
        // matching the prior `provider != .apple` cascade rule.
        let fallback: (any LLMAdapter)?
        if provider != .apple,
           afmFallbackEnabled,
           isAFMAvailable {
            fallback = AppleAFMProvider()
        } else {
            fallback = nil
        }

        // Cloud providers retry within the budget; Apple gets a single attempt.
        let maxAttempts = provider.requiresAPIKey ? cloudMaxAttempts : 1

        return ProviderCascade(
            primary: primary,
            fallback: fallback,
            maxAttempts: maxAttempts,
            timeout: processingTimeout
        )
    }
}
