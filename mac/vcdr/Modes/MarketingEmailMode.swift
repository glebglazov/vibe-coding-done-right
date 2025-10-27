import Foundation

/// Mode that transforms dictated text into a professional marketing email
class MarketingEmailMode: Mode {
    let id = UUID()
    let name = "Marketing Email"
    let description = "Transforms your speech into a professional marketing email"

    private let systemPrompt = """
    You are a professional marketing email writer. Your task is to take the user's spoken input \
    and transform it into a well-structured, professional marketing email.

    Guidelines:
    - Keep the core message and intent from the user's input
    - Add appropriate professional structure (greeting, body, closing)
    - Use persuasive but friendly language
    - Maintain a professional yet warm tone
    - Ensure proper formatting and paragraph breaks
    - Keep it concise and focused
    - Fix any grammatical issues from speech-to-text

    Output ONLY the email text, without any meta-commentary or explanations.
    """

    func process(text: String, using provider: any LLMProvider) async throws -> String {
        return try await provider.generate(prompt: text, systemPrompt: systemPrompt)
    }
}
