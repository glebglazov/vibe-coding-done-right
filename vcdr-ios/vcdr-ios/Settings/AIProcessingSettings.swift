import Foundation

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

/// What a Prompt Mode can be told about AI processing — or, for a mode that
/// processes nothing, why not. The two travel as one answer for the same
/// reason `TranscriptionModelCapabilities` does: a screen built from the
/// declaration can never render no controls and no explanation.
enum AIProcessingCapabilities: Equatable {
    /// This mode sends the transcript to an AI Provider, so it chooses one and
    /// says whether Apple stands behind it.
    case providerAndFallback
    /// This mode sends the transcript nowhere, and this is what its screen says
    /// instead.
    case nothing(because: String)
}

extension AIPromptMode {
    /// What this mode's screen offers for AI processing. Verbatim declares it
    /// processes nothing rather than showing a Provider it would never call.
    var aiProcessing: AIProcessingCapabilities {
        switch self {
        case .verbatim:
            .nothing(because: """
                Verbatim writes down what you said and sends it nowhere, so \
                there is no AI Provider to choose. What it records with is \
                below.
                """)
        case .dictation, .assistant:
            .providerAndFallback
        }
    }
}

/// iOS AI provider selection. Cloud backends come from the shared seam; Apple
/// remains an iOS-only backend registered when AFM is available.
enum AIProvider: RawRepresentable, Codable, Hashable, Sendable {
    case cloud(CloudAIBackend)
    case apple

    static let anthropic = AIProvider.cloud(.anthropic)
    static let openai = AIProvider.cloud(.openai)
    static let gemini = AIProvider.cloud(.gemini)

    init?(rawValue: String) {
        if let cloud = CloudAIBackend(rawValue: rawValue) {
            self = .cloud(cloud)
        } else if rawValue == "apple" {
            self = .apple
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .cloud(let backend): backend.rawValue
        case .apple: "apple"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let provider = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AI provider: \(rawValue)"
            )
        }
        self = provider
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .cloud(let backend): backend.displayName
        case .apple: "Apple"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .cloud: true
        case .apple: false
        }
    }

    var apiKeyVariableName: String {
        switch self {
        case .cloud(let backend): backend.apiKeyVariableName
        case .apple: ""
        }
    }

    /// Whether this provider is ready to use (has API key or AFM available).
    @MainActor
    var isConfigured: Bool {
        switch self {
        case .cloud: !AIProcessingSettings.apiKey(for: self).isEmpty
        case .apple: AIProcessingSettings.isAFMAvailable
        }
    }

    /// Providers that are configured and available for selection.
    @MainActor
    static var configuredProviders: [AIProvider] {
        configuredProviders(isAFMAvailable: AIProcessingSettings.isAFMAvailable)
    }

    @MainActor
    static func configuredProviders(isAFMAvailable: Bool) -> [AIProvider] {
        var providers = CloudAIBackend.allCases
            .map(AIProvider.cloud)
            .filter(\.isConfigured)
        if isAFMAvailable {
            providers.append(.apple)
        }
        return providers
    }
}

/// Reads AI processing settings from UserDefaults, and the Provider API keys from the
/// Secret Store through `ProviderKeyStore`. The settings view writes the rest via
/// @AppStorage and the keys through `setAPIKey(_:for:)`; other code reads through these
/// static properties.
enum AIProcessingSettings {
    static let enabledKey = "ai_processing_enabled"
    static let providerKey = "ai_processing_provider"
    static let dictationProviderKey = "ai_processing_dictation_provider"
    static let assistantProviderKey = "ai_processing_assistant_provider"
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

    /// Provider for the current default mode. Used by hasAICapability / isConfigured checks.
    static var provider: AIProvider {
        provider(for: defaultMode)
    }

    /// Where `mode`'s AI Provider lives. Verbatim doesn't call AI, but
    /// capability checks read this; map it to the dictation provider since
    /// that's the natural first AI mode.
    static func providerKey(for mode: AIPromptMode) -> String {
        switch mode {
        case .verbatim, .dictation: dictationProviderKey
        case .assistant: assistantProviderKey
        }
    }

    /// Where `mode`'s Apple fallback preference lives.
    static func afmFallbackKey(for mode: AIPromptMode) -> String {
        switch mode {
        case .verbatim, .dictation: dictationAfmFallbackKey
        case .assistant: assistantAfmFallbackKey
        }
    }

    static func provider(for mode: AIPromptMode) -> AIProvider {
        let raw = UserDefaults.standard.string(forKey: providerKey(for: mode)) ?? ""
        // Fall back to legacy global provider key for migration
        return AIProvider(rawValue: raw)
            ?? AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "")
            ?? .anthropic
    }

    static var afmFallbackEnabled: Bool {
        UserDefaults.standard.bool(forKey: afmFallbackEnabledKey)
    }

    static func afmFallbackEnabled(for mode: AIPromptMode) -> Bool {
        UserDefaults.standard.bool(forKey: afmFallbackKey(for: mode))
    }

    /// Whether Apple Foundation Models are available on this device
    /// (Apple Intelligence enabled + supported hardware + model downloaded).
    /// Reads the cached probe value — see `AFMAvailabilityCache` for why this
    /// is not a direct `SystemLanguageModel.default.isAvailable` lookup.
    @MainActor
    static var isAFMAvailable: Bool {
        AFMAvailabilityCache.shared.isAvailable
    }

    /// The API key for the currently selected provider.
    @MainActor
    static var activeApiKey: String {
        apiKey(for: provider)
    }

    /// The stored API key for a provider, read through the Secret Store seam.
    @MainActor
    static func apiKey(for provider: AIProvider) -> String {
        switch provider {
        case .cloud(let backend): ProviderKeyStore.current.key(for: backend)
        case .apple: ""
        }
    }

    /// Stores a cloud backend's API key — the one write path for keys the app holds.
    @MainActor
    static func setAPIKey(_ key: String, for backend: CloudAIBackend) {
        ProviderKeyStore.current.setKey(key, for: backend)
    }

    /// Whether AI processing is fully configured: enabled + provider ready.
    @MainActor
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
    @MainActor
    static var hasAICapability: Bool {
        if provider.requiresAPIKey {
            return !activeApiKey.isEmpty
        }
        return isAFMAvailable
    }
}
