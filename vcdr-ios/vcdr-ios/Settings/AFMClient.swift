import Foundation
import FoundationModels

enum AFMClient {
    /// Calls the on-device Apple Foundation Model with the given prompt.
    /// Throws `LanguageModelSession.GenerationError` on failure.
    static func process(text: String, systemPrompt: String) async throws -> String {
        let session = LanguageModelSession {
            systemPrompt
        }
        let response = try await session.respond(to: text)
        return response.content
    }
}
