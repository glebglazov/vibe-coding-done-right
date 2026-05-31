import Foundation

/// On-device Apple Foundation Models adapter. Thin wrapper over `AFMClient`,
/// which stays the FoundationModels primitive. Used both as a primary provider
/// (when the user picks Apple) and as the cascade fallback in `ProviderCascade`.
struct AppleAFMProvider: LLMAdapter {
    var displayName: String { AIProvider.apple.displayName }

    func process(text: String, systemPrompt: String) async throws -> String {
        try await AFMClient.process(text: text, systemPrompt: systemPrompt)
    }
}

extension AIProvider {
    func makeAdapter(apiKey: String) -> any LLMAdapter {
        switch self {
        case .cloud(let backend): backend.makeAdapter(apiKey: apiKey)
        case .apple: AppleAFMProvider()
        }
    }
}
