import Foundation

/// The cloud-backend `AIClientError` of the shared seam: errors thrown by the
/// cloud HTTP adapters, typed on `CloudAIBackend` so logs and UI can name the
/// failing vendor without a platform-specific error enum. Phase 1 carries only
/// the three cloud cases — Apple's `providerUnavailable` is unused today and
/// stays at the iOS platform layer until AFM needs it.
///
/// Named `CloudAIClientError` rather than `AIClientError` only to coexist with
/// the platform-local `AIClientError` enums during the slice-1 extraction; the
/// platform copies are removed and selection rewired in slice 2.
enum CloudAIClientError: LocalizedError {
    case missingAPIKey(provider: CloudAIBackend)
    /// The Secret Store refused to hand over the key. Distinct from `missingAPIKey`
    /// on purpose: the key may well be set, so telling the user to add one would
    /// send them after a key they already have.
    case secretStoreUnreadable(provider: CloudAIBackend)
    case apiError(provider: CloudAIBackend, statusCode: Int, message: String)
    case invalidResponse(provider: CloudAIBackend)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider.displayName) API key is not set. Add \(provider.apiKeyVariableName)."
        case .secretStoreUnreadable(let provider):
            "\(provider.displayName) API key could not be read from the keychain."
        case .apiError(let provider, let statusCode, let message):
            "\(provider.displayName) API error (\(statusCode)): \(message)"
        case .invalidResponse(let provider):
            "Invalid response from \(provider.displayName) API"
        }
    }
}
