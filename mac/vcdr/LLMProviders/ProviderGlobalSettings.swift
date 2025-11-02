import Foundation

// MARK: - Protocol

/// Protocol that defines global settings for a provider type
/// Each provider can define its own set of global configuration properties
protocol ProviderGlobalSettingsProtocol: Codable, Equatable {
    /// The provider type this settings object is for
    static var providerType: ProviderType { get }

    /// Display name for this provider
    static var displayName: String { get }

    /// Description of what these settings are for
    static var settingsDescription: String { get }
}

// MARK: - Apple Foundation Models Settings

struct AppleFoundationModelsGlobalSettings: ProviderGlobalSettingsProtocol {
    static let providerType: ProviderType = .appleFoundationModels
    static let displayName = "Apple Foundation Models"
    static let settingsDescription = "Apple's on-device language models require no configuration."

    // No settings needed for Apple Foundation Models
}

// MARK: - Ollama Settings

struct OllamaGlobalSettings: ProviderGlobalSettingsProtocol {
    static let providerType: ProviderType = .ollama
    static let displayName = "Ollama"
    static let settingsDescription = "Default settings for Ollama instances. Can be overridden per model."

    var defaultBaseURL: String = "http://localhost:11434"
}

// MARK: - Storage

/// Manages global provider settings across all provider types
class GlobalProviderSettingsStorage {
    static let shared = GlobalProviderSettingsStorage()

    private let ollamaSettingsKey = "com.vcdr.globalSettings.ollama"
    private let appleSettingsKey = "com.vcdr.globalSettings.apple"

    private let userDefaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = .prettyPrinted
    }

    // MARK: - Ollama Settings

    func loadOllamaSettings() -> OllamaGlobalSettings {
        guard let data = userDefaults.data(forKey: ollamaSettingsKey) else {
            print("📦 No Ollama global settings found, using defaults")
            return OllamaGlobalSettings()
        }

        do {
            let settings = try decoder.decode(OllamaGlobalSettings.self, from: data)
            print("📦 Loaded Ollama global settings")
            return settings
        } catch {
            print("❌ Failed to decode Ollama settings: \(error)")
            return OllamaGlobalSettings()
        }
    }

    func saveOllamaSettings(_ settings: OllamaGlobalSettings) {
        do {
            let data = try encoder.encode(settings)
            userDefaults.set(data, forKey: ollamaSettingsKey)
            print("💾 Saved Ollama global settings")
        } catch {
            print("❌ Failed to encode Ollama settings: \(error)")
        }
    }

    // MARK: - Apple Foundation Models Settings

    func loadAppleSettings() -> AppleFoundationModelsGlobalSettings {
        // Apple Foundation Models don't need configuration, just return defaults
        return AppleFoundationModelsGlobalSettings()
    }

    func saveAppleSettings(_ settings: AppleFoundationModelsGlobalSettings) {
        // Nothing to save for Apple Foundation Models
    }
}

// MARK: - Helper for UI

/// Helper to work with global settings in a type-erased way for UI
struct GlobalSettingsWrapper {
    let providerType: ProviderType
    let displayName: String
    let description: String
    let hasSettings: Bool

    static let allProviders: [GlobalSettingsWrapper] = [
        GlobalSettingsWrapper(
            providerType: .ollama,
            displayName: OllamaGlobalSettings.displayName,
            description: OllamaGlobalSettings.settingsDescription,
            hasSettings: true
        ),
        GlobalSettingsWrapper(
            providerType: .appleFoundationModels,
            displayName: AppleFoundationModelsGlobalSettings.displayName,
            description: AppleFoundationModelsGlobalSettings.settingsDescription,
            hasSettings: false
        )
    ]
}
