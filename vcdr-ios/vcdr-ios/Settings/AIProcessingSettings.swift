import Foundation
import FoundationModels

/// Available AI processing prompt modes.
/// Raw values match the server's prompt keys for cache lookup.
enum AIPromptMode: String, CaseIterable, Codable {
    case verbatim
    case dictation
    case assistant

    var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .dictation: "Dictation"
        case .assistant: "Assistant"
        }
    }

    /// Whether this mode is currently available for selection.
    /// Used to filter the picker — allows defining enum cases before they're ready.
    var isAvailable: Bool {
        switch self {
        case .verbatim: true
        case .dictation: true
        case .assistant: true
        }
    }

    /// Modes that should appear in the UI picker.
    static var availableModes: [AIPromptMode] {
        allCases.filter(\.isAvailable)
    }

    /// Whether style transformations (capitalization, punctuation) should be applied for this mode.
    /// Verbatim and dictation produce user text that benefits from styling; assistant produces AI output that shouldn't be restyled.
    var appliesStyles: Bool {
        switch self {
        case .verbatim: true
        case .dictation: true
        case .assistant: false
        }
    }

}

/// AI provider selection — matches the macOS AIProvider enum.
enum AIProvider: String, Codable, CaseIterable {
    case anthropic
    case openai
    case apple

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .apple: "Apple"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openai: true
        case .apple: false
        }
    }

    var apiKeyVariableName: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OPENAI_API_KEY"
        case .apple: ""
        }
    }

    /// Whether this provider is ready to use (has API key or AFM available).
    var isConfigured: Bool {
        switch self {
        case .anthropic: !AIProcessingSettings.anthropicApiKey.isEmpty
        case .openai: !AIProcessingSettings.openaiApiKey.isEmpty
        case .apple: AIProcessingSettings.isAFMAvailable
        }
    }

    /// Providers that are configured and available for selection.
    static var configuredProviders: [AIProvider] {
        allCases.filter(\.isConfigured)
    }
}

/// Reads AI processing settings from UserDefaults.
/// The settings view writes via @AppStorage; other code reads through these static properties.
enum AIProcessingSettings {
    static let enabledKey = "ai_processing_enabled"
    static let providerKey = "ai_processing_provider"
    static let dictationProviderKey = "ai_processing_dictation_provider"
    static let assistantProviderKey = "ai_processing_assistant_provider"
    static let anthropicApiKeyKey = "ai_processing_anthropic_api_key"
    static let openaiApiKeyKey = "ai_processing_openai_api_key"
    static let afmFallbackEnabledKey = "ai_processing_afm_fallback_enabled"
    static let dictationAfmFallbackKey = "ai_processing_dictation_afm_fallback"
    static let assistantAfmFallbackKey = "ai_processing_assistant_afm_fallback"
    /// Remembers the user's fallback preference so it can be restored when
    /// switching away from Apple as primary provider.
    static let afmFallbackRememberedKey = "ai_processing_afm_fallback_remembered"

    /// Default mode as configured in Settings. Reads from `sharedDefaults` so
    /// both the main app and keyboard extension see the same value; mutations
    /// go through `DefaultSettings.setAIMode(_:)`.
    static var defaultMode: AIPromptMode {
        let raw = SharedConstants.sharedDefaults.string(forKey: SharedConstants.defaultAIModeKey) ?? ""
        return AIPromptMode(rawValue: raw) ?? .verbatim
    }

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Whether AI is on by default for new dictation sessions. Reads from
    /// `sharedDefaults`; mutations go through `DefaultSettings.setAIActive(_:)`.
    static var activeInDictation: Bool {
        SharedConstants.sharedDefaults.bool(forKey: SharedConstants.defaultAIActiveKey)
    }

    /// Provider for the current default mode. Used by hasAICapability / isConfigured checks.
    static var provider: AIProvider {
        provider(for: defaultMode)
    }

    static func provider(for mode: AIPromptMode) -> AIProvider {
        // Verbatim doesn't call AI, but capability checks read this; map it to
        // the dictation provider since that's the natural first AI mode.
        let key: String
        switch mode {
        case .verbatim, .dictation: key = dictationProviderKey
        case .assistant: key = assistantProviderKey
        }
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        // Fall back to legacy global provider key for migration
        return AIProvider(rawValue: raw)
            ?? AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "")
            ?? .anthropic
    }

    static var anthropicApiKey: String {
        UserDefaults.standard.string(forKey: anthropicApiKeyKey) ?? ""
    }

    static var openaiApiKey: String {
        UserDefaults.standard.string(forKey: openaiApiKeyKey) ?? ""
    }

    static var afmFallbackEnabled: Bool {
        UserDefaults.standard.bool(forKey: afmFallbackEnabledKey)
    }

    static func afmFallbackEnabled(for mode: AIPromptMode) -> Bool {
        let key: String
        switch mode {
        case .verbatim, .dictation: key = dictationAfmFallbackKey
        case .assistant: key = assistantAfmFallbackKey
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Whether Apple Foundation Models are available on this device
    /// (Apple Intelligence enabled + supported hardware + model downloaded).
    static var isAFMAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// The API key for the currently selected provider.
    static var activeApiKey: String {
        apiKey(for: provider)
    }

    static func apiKey(for provider: AIProvider) -> String {
        switch provider {
        case .anthropic: anthropicApiKey
        case .openai: openaiApiKey
        case .apple: ""
        }
    }

    /// Whether AI processing is fully configured: enabled + provider ready.
    static var isConfigured: Bool {
        guard enabled else { return false }
        if provider.requiresAPIKey {
            return !activeApiKey.isEmpty
        }
        return isAFMAvailable
    }

    /// Whether AI can be used if toggled on — API key exists or AFM available.
    /// Unlike `isConfigured`, does not require the global `enabled` flag.
    /// Used to show/hide the per-session AI toggle in recording and keyboard.
    static var hasAICapability: Bool {
        if provider.requiresAPIKey {
            return !activeApiKey.isEmpty
        }
        return isAFMAvailable
    }
}
