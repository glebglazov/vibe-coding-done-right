import Foundation

/// Protocol defining a mode that processes dictated text
protocol Mode: Identifiable {
    /// Unique identifier for the mode
    var id: UUID { get }

    /// Display name of the mode
    var name: String { get }

    /// Description of what this mode does
    var description: String { get }

    /// Process the transcribed text
    /// - Parameter text: The raw transcribed text from WhisperKit
    /// - Returns: The processed text (or original text if no processing needed)
    func process(text: String, using provider: any LLMProvider) async throws -> String
}
