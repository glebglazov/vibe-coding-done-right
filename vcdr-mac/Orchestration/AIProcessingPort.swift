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
    ///   - spellingHints: The Dictionary's Spelling Hints, appended after the mode's prompt.
    ///   - apiKey: The AI Provider's stored API key — the single source of truth for AI
    ///     calls. Resolved by the caller from `AppSettings`, never from a Variable.
    ///   - parameterValues: Resolved parameter values (e.g. model selection overrides)
    ///     keyed by environment-variable suffix (e.g. "MODEL").
    /// - Returns: The provider's response text.
    func process(
        structuredText: String,
        mode: Mode,
        spellingHints: SpellingHints,
        apiKey: String,
        parameterValues: [String: String]
    ) async throws -> String
}

/// Production adapter. Owns prompt resolution and routes provider construction
/// through `AIProviderFactory` so the initial call and retry path share the
/// same timeout/retry/fallback policy.
struct AIProcessingAdapter: AIProcessingPort {
    func process(
        structuredText: String,
        mode: Mode,
        spellingHints: SpellingHints,
        apiKey: String,
        parameterValues: [String: String]
    ) async throws -> String {
        let systemPrompt = Self.systemPrompt(for: mode, spellingHints: spellingHints)
        let provider = AIProviderFactory.make(
            for: mode,
            apiKey: apiKey
        )
        return try await provider.process(
            text: structuredText,
            systemPrompt: systemPrompt
        )
    }

    static func systemPrompt(for mode: Mode, spellingHints: SpellingHints) -> String {
        spellingHints.appended(to: resolvePrompt(mode), detail: mode.promptType.hintDetail)
    }

    /// Resolves the system prompt for the given mode's prompt type.
    /// Shared by Cloud AI and Local Agent; a Bash Script reads `mode.systemPrompt` directly.
    static func resolvePrompt(_ mode: Mode) -> String {
        switch mode.promptType {
        case .dictation: BuiltInPrompts.dictation
        case .custom: mode.systemPrompt
        }
    }
}
