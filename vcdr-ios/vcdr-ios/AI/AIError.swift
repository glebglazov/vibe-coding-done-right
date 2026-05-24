import Foundation

/// Errors thrown by the LLM adapters. Carries the originating `AIProvider` so
/// messages can name the backend that failed.
enum AIClientError: LocalizedError {
    case missingAPIKey(provider: AIProvider)
    case apiError(provider: AIProvider, statusCode: Int, message: String)
    case invalidResponse(provider: AIProvider)
    case providerUnavailable(provider: AIProvider)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider.displayName) API key is not set."
        case .apiError(let provider, let statusCode, let message):
            "\(provider.displayName) API error (\(statusCode)): \(message)"
        case .invalidResponse(let provider):
            "Invalid response from \(provider.displayName) API"
        case .providerUnavailable(let provider):
            "\(provider.displayName) is not available on this device."
        }
    }
}
