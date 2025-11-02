import Foundation
import SwiftUI
import Combine

/// Manages modes and LLM providers for text processing
@MainActor
class ModeManager: ObservableObject {
    static let shared = ModeManager()

    /// Whether mode processing is enabled
    @Published var isEnabled: Bool = true

    /// Currently active mode (nil means PassThrough)
    @Published var activeMode: (any Mode)?

    /// Currently active LLM provider
    @Published var activeLLMProvider: any LLMProvider

    /// All available modes (built-in + custom)
    @Published var availableModes: [any Mode]

    /// Built-in modes (cannot be deleted)
    let builtInModes: [any Mode]

    /// Custom modes (can be edited/deleted)
    @Published var customModes: [CustomMode] = []

    /// All available LLM provider configurations
    @Published var providerConfigurations: [ProviderConfiguration] = []

    /// All available LLM provider instances
    @Published var availableProviders: [any LLMProvider] = []

    /// Track the last used custom mode for quick access with 'c' shortcut
    @Published var lastUsedCustomMode: CustomMode?

    private let customModesStorage = CustomModesStorage.shared
    private let providerConfigurationsStorage = ProvidersStorage.shared

    private init() {
        // Initialize built-in modes
        let modes: [any Mode] = [
            DisabledMode(),
            AssistantMode()
        ]
        builtInModes = modes

        // Load custom modes from storage
        let loadedCustomModes = CustomModesStorage.shared.loadCustomModes()
        customModes = loadedCustomModes

        // Combine built-in and custom modes
        availableModes = modes + loadedCustomModes

        // Load provider configurations and create instances
        let configs = ProvidersStorage.shared.loadConfigurations()
        providerConfigurations = configs

        let providers = configs
            .filter { $0.isEnabled }
            .compactMap { Self.createProviderInstance(from: $0) }
        availableProviders = providers

        // Set defaults
        activeMode = modes.first // DisabledMode by default

        // Set active provider from storage or use first available
        if let savedProviderId = ProvidersStorage.shared.getActiveProviderId(),
           let savedProvider = providers.first(where: { $0.id == savedProviderId }) {
            activeLLMProvider = savedProvider
            print("✅ Restored saved provider: \(savedProvider.name)")
        } else if let firstProvider = providers.first {
            activeLLMProvider = firstProvider
            providerConfigurationsStorage.setActiveProviderId(firstProvider.id)
            print("✅ Using first available provider: \(firstProvider.name)")
        } else {
            // Fallback to a default provider if none are available
            let fallback = FoundationModelsProvider()
            availableProviders = [fallback]
            activeLLMProvider = fallback
            providerConfigurationsStorage.setActiveProviderId(fallback.id)
            print("⚠️ No providers configured, using fallback: \(fallback.name)")
        }
    }

    /// Process text through the active mode
    /// - Parameter text: The raw transcribed text
    /// - Returns: Processed text (or original if mode is disabled/PassThrough)
    func processText(_ text: String) async throws -> String {
        // If mode processing is disabled, return raw text
        guard isEnabled else {
            return text
        }

        // If no active mode, return raw text
        guard let mode = activeMode else {
            return text
        }

        // If DisabledMode, no processing needed
        if mode is DisabledMode {
            return text
        }

        // Process through the mode (let provider handle availability errors)
        return try await mode.process(text: text, using: activeLLMProvider)
    }

    /// Set the active mode by name
    func setMode(named name: String) {
        activeMode = availableModes.first { $0.name == name }
    }

    /// Set the active mode
    func setMode(_ mode: any Mode) {
        activeMode = mode

        // Track if this is a custom mode for quick access with 'c' shortcut
        if let customMode = mode as? CustomMode {
            lastUsedCustomMode = customMode
            print("💾 Tracked last used custom mode: \(customMode.name)")
        }
    }

    /// Set the active LLM provider
    func setProvider(_ provider: any LLMProvider) {
        activeLLMProvider = provider
        providerConfigurationsStorage.setActiveProviderId(provider.id)
    }

    /// Cycle through custom modes using 'c' shortcut
    /// - If no custom mode is active, switches to last used custom mode (or first if none used)
    /// - If a custom mode is active, cycles to next custom mode in list
    func cycleCustomMode() {
        guard !customModes.isEmpty else {
            print("⚠️ No custom modes available to cycle")
            return
        }

        // Check if current mode is a custom mode
        if let currentCustomMode = activeMode as? CustomMode,
           let currentIndex = customModes.firstIndex(where: { $0.id == currentCustomMode.id }) {
            // Cycle to next custom mode
            let nextIndex = (currentIndex + 1) % customModes.count
            let nextMode = customModes[nextIndex]
            setMode(nextMode)
            print("🔄 Cycled to next custom mode: \(nextMode.name)")
        } else {
            // Not currently on a custom mode, switch to last used or first
            let targetMode = lastUsedCustomMode ?? customModes.first!
            setMode(targetMode)
            print("🔄 Switched to custom mode: \(targetMode.name)")
        }
    }

    /// Add a new custom mode
    func addCustomMode(_ mode: CustomMode) {
        customModesStorage.addCustomMode(mode)
        customModes.append(mode)
        availableModes = builtInModes + customModes
        print("➕ Added custom mode: \(mode.name)")
    }

    /// Update an existing custom mode
    func updateCustomMode(_ mode: CustomMode) {
        customModesStorage.updateCustomMode(mode)
        if let index = customModes.firstIndex(where: { $0.id == mode.id }) {
            customModes[index] = mode
            availableModes = builtInModes + customModes
            print("✏️ Updated custom mode: \(mode.name)")
        }
    }

    /// Delete a custom mode
    func deleteCustomMode(_ mode: CustomMode) {
        customModesStorage.deleteCustomMode(mode)
        customModes.removeAll { $0.id == mode.id }
        availableModes = builtInModes + customModes

        // If the deleted mode was active, switch to DisabledMode
        if activeMode?.id == mode.id {
            activeMode = builtInModes.first
        }

        print("🗑️ Deleted custom mode: \(mode.name)")
    }

    /// Check if a mode is custom (can be edited/deleted)
    func isCustomMode(_ mode: any Mode) -> Bool {
        return customModes.contains(where: { $0.id == mode.id })
    }

    // MARK: - Provider Management

    /// Create a provider instance from a configuration
    private static func createProviderInstance(from config: ProviderConfiguration) -> (any LLMProvider)? {
        switch config.providerType {
        case .appleFoundationModels:
            let provider = FoundationModelsProvider(id: config.id)
            return provider

        case .ollama:
            guard let modelName = config.ollamaModelName else {
                print("⚠️ Ollama config missing model name: \(config.displayName)")
                return nil
            }
            let baseURL = config.ollamaBaseURL ?? "http://localhost:11434"
            let provider = OllamaProvider(id: config.id, name: config.displayName, modelName: modelName, baseURL: baseURL)
            return provider

        case .anthropic:
            guard let modelName = config.anthropicModelName else {
                print("⚠️ Anthropic config missing model name: \(config.displayName)")
                return nil
            }
            let provider = AnthropicProvider(id: config.id, name: config.displayName, modelName: modelName)
            return provider
        }
    }

    /// Reload providers from configurations
    func reloadProviders() {
        providerConfigurations = providerConfigurationsStorage.loadConfigurations()
        availableProviders = providerConfigurations
            .filter { $0.isEnabled }
            .compactMap { Self.createProviderInstance(from: $0) }

        // If active provider is no longer available, switch to first available
        if !availableProviders.contains(where: { $0.id == activeLLMProvider.id }) {
            if let firstProvider = availableProviders.first {
                activeLLMProvider = firstProvider
                providerConfigurationsStorage.setActiveProviderId(firstProvider.id)
                print("⚠️ Active provider no longer available, switched to: \(firstProvider.name)")
            }
        }
    }

    /// Add a new provider configuration
    func addProviderConfiguration(_ config: ProviderConfiguration) {
        providerConfigurationsStorage.addConfiguration(config)
        reloadProviders()
        print("➕ Added provider configuration: \(config.displayName)")
    }

    /// Update an existing provider configuration
    func updateProviderConfiguration(_ config: ProviderConfiguration) {
        providerConfigurationsStorage.updateConfiguration(config)
        reloadProviders()
        print("✏️ Updated provider configuration: \(config.displayName)")
    }

    /// Delete a provider configuration
    func deleteProviderConfiguration(_ config: ProviderConfiguration) {
        providerConfigurationsStorage.deleteConfiguration(config)
        reloadProviders()
        print("🗑️ Deleted provider configuration: \(config.displayName)")
    }

    /// Get configuration for a provider
    func getConfiguration(for provider: any LLMProvider) -> ProviderConfiguration? {
        return providerConfigurations.first { config in
            // Match by type and specific properties
            switch config.providerType {
            case .appleFoundationModels:
                return provider is FoundationModelsProvider
            case .ollama:
                if let ollamaProvider = provider as? OllamaProvider {
                    return ollamaProvider.modelName == config.ollamaModelName &&
                           ollamaProvider.baseURL == (config.ollamaBaseURL ?? "http://localhost:11434")
                }
                return false
            case .anthropic:
                if let anthropicProvider = provider as? AnthropicProvider {
                    return anthropicProvider.modelName == config.anthropicModelName
                }
                return false
            }
        }
    }

}

/// Errors that can occur during mode processing
enum ModeError: LocalizedError {
    case providerUnavailable
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return "LLM provider is not available. Please check your settings."
        case .processingFailed(let message):
            return "Failed to process text: \(message)"
        }
    }
}
