import Foundation

/// AI provider selection — matches the macOS AIProvider enum.
enum AIProvider: String, Codable, CaseIterable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }

    var apiKeyVariableName: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OPENAI_API_KEY"
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

    /// The API key for the currently selected provider.
    static var activeApiKey: String {
        switch provider {
        case .anthropic: anthropicApiKey
        case .openai: openaiApiKey
        }
    }

    /// Whether AI processing is fully configured: enabled + API key set for selected provider.
    static var isConfigured: Bool {
        enabled && !activeApiKey.isEmpty
    }
}
