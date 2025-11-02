import Foundation

/// Configuration for an LLM provider instance
struct ProviderConfiguration: Identifiable, Codable, Equatable {
    let id: UUID
    var providerType: ProviderType
    var isEnabled: Bool

    // Ollama-specific settings
    var ollamaModelName: String?
    var ollamaBaseURL: String?

    init(
        id: UUID = UUID(),
        providerType: ProviderType,
        isEnabled: Bool = true,
        ollamaModelName: String? = nil,
        ollamaBaseURL: String? = nil
    ) {
        self.id = id
        self.providerType = providerType
        self.isEnabled = isEnabled
        self.ollamaModelName = ollamaModelName
        self.ollamaBaseURL = ollamaBaseURL
    }

    /// Auto-generated display name based on provider type and configuration
    var displayName: String {
        switch providerType {
        case .appleFoundationModels:
            return "Apple Foundation Models"
        case .ollama:
            guard let modelName = ollamaModelName else {
                return "Ollama"
            }
            let baseURL = ollamaBaseURL ?? "http://localhost:11434"

            // Extract host and port from URL for cleaner display
            if let url = URL(string: baseURL) {
                let host = url.host ?? "localhost"
                let port = url.port ?? 11434

                // Only show host if it's not localhost, or if port is non-standard
                if host != "localhost" {
                    return "Ollama (\(modelName) @ \(host):\(port))"
                } else if port != 11434 {
                    return "Ollama (\(modelName) @ localhost:\(port))"
                } else {
                    return "Ollama (\(modelName))"
                }
            }

            return "Ollama (\(modelName))"
        }
    }

    /// Create a default Apple Foundation Models configuration
    static func appleFoundationModels() -> ProviderConfiguration {
        ProviderConfiguration(
            providerType: .appleFoundationModels
        )
    }

    /// Create a default Ollama configuration
    static func ollama(modelName: String = "llama3.2:3b", baseURL: String = "http://localhost:11434") -> ProviderConfiguration {
        ProviderConfiguration(
            providerType: .ollama,
            ollamaModelName: modelName,
            ollamaBaseURL: baseURL
        )
    }
}

/// Supported provider types
enum ProviderType: String, Codable {
    case appleFoundationModels = "apple"
    case ollama = "ollama"
}

/// Manages persistence of provider configurations
class ProvidersStorage {
    static let shared = ProvidersStorage()

    private let storageKey = "com.vcdr.providerConfigurations"
    private let activeProviderKey = "com.vcdr.activeProviderId"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = .prettyPrinted
    }

    /// Load all provider configurations from storage
    func loadConfigurations() -> [ProviderConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            print("📦 No provider configurations found, creating defaults")
            return createDefaultConfigurations()
        }

        do {
            let configs = try decoder.decode([ProviderConfiguration].self, from: data)
            print("📦 Loaded \(configs.count) provider configuration(s)")
            return configs
        } catch {
            print("❌ Failed to decode provider configurations: \(error)")
            return createDefaultConfigurations()
        }
    }

    /// Save provider configurations to storage
    func saveConfigurations(_ configs: [ProviderConfiguration]) {
        do {
            let data = try encoder.encode(configs)
            UserDefaults.standard.set(data, forKey: storageKey)
            print("💾 Saved \(configs.count) provider configuration(s)")
        } catch {
            print("❌ Failed to encode provider configurations: \(error)")
        }
    }

    /// Add a new provider configuration
    func addConfiguration(_ config: ProviderConfiguration) {
        var configs = loadConfigurations()
        configs.append(config)
        saveConfigurations(configs)
    }

    /// Update an existing provider configuration
    func updateConfiguration(_ config: ProviderConfiguration) {
        var configs = loadConfigurations()
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
            saveConfigurations(configs)
            print("✏️ Updated provider configuration: \(config.displayName)")
        }
    }

    /// Delete a provider configuration
    func deleteConfiguration(_ config: ProviderConfiguration) {
        var configs = loadConfigurations()
        configs.removeAll { $0.id == config.id }
        saveConfigurations(configs)
        print("🗑️ Deleted provider configuration: \(config.displayName)")
    }

    /// Get the active provider ID
    func getActiveProviderId() -> UUID? {
        guard let uuidString = UserDefaults.standard.string(forKey: activeProviderKey),
              let uuid = UUID(uuidString: uuidString) else {
            return nil
        }
        return uuid
    }

    /// Set the active provider ID
    func setActiveProviderId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeProviderKey)
        print("✅ Set active provider: \(id)")
    }

    /// Create default provider configurations
    private func createDefaultConfigurations() -> [ProviderConfiguration] {
        return [
            .appleFoundationModels(),
            .ollama(modelName: "llama3.2:3b")
        ]
    }
}
