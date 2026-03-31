import Foundation
import FoundationModels

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
}

/// Reads AI processing settings from UserDefaults.
/// The settings view writes via @AppStorage; other code reads through these static properties.
enum AIProcessingSettings {
    static let enabledKey = "ai_processing_enabled"
    static let activeInDictationKey = "ai_processing_active_in_dictation"
    static let providerKey = "ai_processing_provider"
    static let anthropicApiKeyKey = "ai_processing_anthropic_api_key"
    static let openaiApiKeyKey = "ai_processing_openai_api_key"
    static let afmFallbackEnabledKey = "ai_processing_afm_fallback_enabled"
    /// Remembers the user's fallback preference so it can be restored when
    /// switching away from Apple as primary provider.
    static let afmFallbackRememberedKey = "ai_processing_afm_fallback_remembered"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var activeInDictation: Bool {
        UserDefaults.standard.bool(forKey: activeInDictationKey)
    }

    static var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .anthropic
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

    /// Whether Apple Foundation Models are available on this device
    /// (Apple Intelligence enabled + supported hardware + model downloaded).
    static var isAFMAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// The API key for the currently selected provider.
    static var activeApiKey: String {
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
}
