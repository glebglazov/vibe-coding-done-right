import Foundation

/// One AI Provider's API Key as the Secret Store answered for it, carried through the
/// processing pipeline in place of a bare `String`. A read the Store refused travels as
/// `.unreadable` rather than as an empty key, so the AI call can say the Store could not
/// be read instead of telling the user to add a key that is already there.
enum ProviderAPIKey: Sendable, Equatable {
    /// The key the Store holds. Empty when the provider has no key set.
    case stored(String)
    /// The Store could not be read for this provider.
    case unreadable

    /// The key to hand the backend's LLM Adapter, or the Store failure that stops the call.
    func resolved(for backend: CloudAIBackend) throws -> String {
        switch self {
        case .stored(let key): return key
        case .unreadable: throw CloudAIClientError.secretStoreUnreadable(provider: backend)
        }
    }
}
