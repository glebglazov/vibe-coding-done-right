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

    /// All available LLM providers
    let availableProviders: [any LLMProvider]

    /// Track the last used custom mode for quick access with 'c' shortcut
    @Published var lastUsedCustomMode: CustomMode?

    private let storage = CustomModesStorage.shared

    private init() {
        // Initialize built-in modes
        builtInModes = [
            DisabledMode(),
            AssistantMode()
        ]

        // Load custom modes from storage
        let loadedCustomModes = storage.loadCustomModes()
        customModes = loadedCustomModes

        // Combine built-in and custom modes
        availableModes = builtInModes + loadedCustomModes

        // Initialize LLM providers
        let foundationModelsProvider = FoundationModelsProvider()
        availableProviders = [
            foundationModelsProvider
        ]

        // Set defaults
        activeLLMProvider = foundationModelsProvider
        activeMode = availableModes.first // DisabledMode by default
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
        storage.addCustomMode(mode)
        customModes.append(mode)
        availableModes = builtInModes + customModes
        print("➕ Added custom mode: \(mode.name)")
    }

    /// Update an existing custom mode
    func updateCustomMode(_ mode: CustomMode) {
        storage.updateCustomMode(mode)
        if let index = customModes.firstIndex(where: { $0.id == mode.id }) {
            customModes[index] = mode
            availableModes = builtInModes + customModes
            print("✏️ Updated custom mode: \(mode.name)")
        }
    }

    /// Delete a custom mode
    func deleteCustomMode(_ mode: CustomMode) {
        storage.deleteCustomMode(mode)
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
