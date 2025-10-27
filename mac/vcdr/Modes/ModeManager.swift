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

    /// All available modes
    let availableModes: [any Mode]

    /// All available LLM providers
    let availableProviders: [any LLMProvider]

    private init() {
        // Initialize built-in modes
        availableModes = [
            PassThroughMode(),
            MarketingEmailMode()
        ]

        // Initialize LLM providers
        let foundationModelsProvider = FoundationModelsProvider()
        availableProviders = [
            foundationModelsProvider
        ]

        // Set defaults
        activeLLMProvider = foundationModelsProvider
        activeMode = availableModes.first // PassThroughMode by default
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

        // If PassThroughMode, no processing needed
        if mode is PassThroughMode {
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
    }

    /// Set the active LLM provider
    func setProvider(_ provider: any LLMProvider) {
        activeLLMProvider = provider
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
