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

    /// Maps a thrown AFM error to a short, user-facing reason in the app's
    /// brutalist (uppercase, terse) style. `isAvailable` can be `true` while
    /// individual requests still fail — most commonly when the user speaks
    /// a language Apple Intelligence doesn't yet support.
    static func friendlyReason(for error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .unsupportedLanguageOrLocale:
                return "Apple Intelligence doesn't support this language"
            default:
                return "Apple Intelligence: \(generationError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
