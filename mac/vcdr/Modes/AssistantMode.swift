import Foundation

/// Mode that uses AI as a general assistant without specific transformations
class AssistantMode: Mode {
    let id = UUID()
    let name = "Assistant"
    let description = "General AI assistance - responds to your requests"

    private let systemPrompt = """
    You are a helpful AI assistant.

    \(baseInputStructurePrompt)

    ASSISTANT MODE INSTRUCTIONS:
    Respond naturally and helpfully to the user's requests or questions. Be concise, clear, and helpful. Provide direct answers without unnecessary preamble.
    """

    func process(text: String, using provider: any LLMProvider) async throws -> String {
        return try await provider.generate(prompt: text, systemPrompt: systemPrompt)
    }
}
