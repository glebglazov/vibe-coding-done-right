import Foundation

/// Mode that uses AI as a general assistant without specific transformations
class AssistantMode: Mode {
    let id = UUID()
    let name = "Assistant"
    let description = "General AI assistance - responds to your requests"

    private let systemPrompt = """
    You are a helpful AI assistant. The user will provide you with text and possibly some context. \
    Respond naturally and helpfully to their requests or questions.

    If the user provides "Selected text:" followed by their response, use the selected text as \
    context for your answer.

    Be concise, clear, and helpful. Provide direct answers without unnecessary preamble.
    """

    func process(text: String, using provider: any LLMProvider) async throws -> String {
        return try await provider.generate(prompt: text, systemPrompt: systemPrompt)
    }
}
