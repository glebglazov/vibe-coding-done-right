import Foundation

/// Protocol defining the interface for LLM providers (Apple Foundation Models, Ollama, Anthropic, etc.)
protocol LLMProvider: Identifiable {
    /// Unique identifier for the provider
    var id: UUID { get }

    /// Display name of the provider (e.g., "Apple Foundation Models", "Ollama")
    var name: String { get }

    /// Whether this provider requires an API key
    var requiresAPIKey: Bool { get }

    /// Check if the provider is available and ready to use
    var isAvailable: Bool { get async }

    /// Generate text using the provider's LLM
    /// - Parameters:
    ///   - prompt: The user's input text
    ///   - systemPrompt: Optional system instructions for the model
    /// - Returns: The generated text from the LLM
    func generate(prompt: String, systemPrompt: String?) async throws -> String
}
