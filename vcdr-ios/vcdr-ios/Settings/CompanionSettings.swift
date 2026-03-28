import Foundation

/// Reads companion server settings from UserDefaults.
/// The settings view writes via @AppStorage; other code reads through these static properties.
enum CompanionSettings {
    static let enabledKey = "companion_enabled"
    static let hostKey = "companion_host"
    static let apiKeyKey = "companion_api_key"
    static let activeInDictationKey = "companion_active_in_dictation"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var host: String {
        UserDefaults.standard.string(forKey: hostKey) ?? ""
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: apiKeyKey) ?? ""
    }

    /// Whether companion processing is enabled by default in dictation (deep-link) sessions.
    static var activeInDictation: Bool {
        UserDefaults.standard.bool(forKey: activeInDictationKey)
    }

    /// Whether the companion is properly configured (enabled + has host + has key).
    static var isConfigured: Bool {
        enabled && !host.isEmpty && !apiKey.isEmpty
    }

    /// Populates settings from a QR deeplink and enables the companion.
    static func configureFromDeepLink(host: String, apiKey: String) {
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set(host, forKey: hostKey)
        UserDefaults.standard.set(apiKey, forKey: apiKeyKey)
        UserDefaults.standard.set(true, forKey: activeInDictationKey)
    }
}
