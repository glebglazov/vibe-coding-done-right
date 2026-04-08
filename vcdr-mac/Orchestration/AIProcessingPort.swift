import Foundation

/// Boundary between the submission pipeline and cloud AI providers.
/// Both the initial AI call inside `TextProcessingPipeline` and the user-triggered
/// retry inside `CaptureSession` route through this port — guaranteeing they
/// share one code path for prompt resolution, provider dispatch, and the API call.
protocol AIProcessingPort: Sendable {
    /// Processes pre-structured input text through the AI provider configured on `mode`.
    ///
    /// - Parameters:
    ///   - structuredText: The AI request body — already wrapped in `<dictation>` tags
    ///     and augmented with capture context by the caller. The port does NOT re-structure.
    ///   - mode: Supplies `aiProvider` and the prompt (via the adapter's prompt resolver).
    ///   - variableEnvironment: User-defined variables; the adapter reads the provider's
    ///     API key from this dictionary.
    /// - Returns: The provider's response text.
    func process(
        structuredText: String,
        mode: Mode,
        variableEnvironment: [String: String]
    ) async throws -> String
}

/// Production adapter. Owns prompt resolution + provider dispatch so the retry path
/// cannot drift away from the initial call.
struct AIProcessingAdapter: AIProcessingPort {
    func process(
        structuredText: String,
        mode: Mode,
        variableEnvironment: [String: String]
    ) async throws -> String {
        let systemPrompt = Self.resolvePrompt(mode)
        let apiKey = variableEnvironment[mode.aiProvider.apiKeyVariableName] ?? ""
        return try await AIClient.process(
            text: structuredText,
            systemPrompt: systemPrompt,
            provider: mode.aiProvider,
            apiKey: apiKey
        )
    }

    /// Resolves the system prompt for the given mode's prompt type.
    /// Shared by all processing types that use prompts (cloudAI, localAgent, bashScript with prompt).
    static func resolvePrompt(_ mode: Mode) -> String {
        switch mode.promptType {
        case .dictation: BuiltInPrompts.dictation
        case .assistant: BuiltInPrompts.assistant
        case .custom: mode.systemPrompt
        }
    }
}
