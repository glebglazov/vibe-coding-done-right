import Foundation

/// Errors thrown by concrete LLM adapters. Carries the originating provider so
/// UI and logs can surface an actionable message.
enum AIClientError: LocalizedError {
    case missingAPIKey(provider: AIProvider)
    case apiError(provider: AIProvider, statusCode: Int, message: String)
    case invalidResponse(provider: AIProvider)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider.displayName) API key is not set. Add \(provider.apiKeyVariableName) in Variables."
        case .apiError(let provider, let statusCode, let message):
            "\(provider.displayName) API error (\(statusCode)): \(message)"
        case .invalidResponse(let provider):
            "Invalid response from \(provider.displayName) API"
        }
    }
}
