import Foundation

/// One non-streaming text-enhancement call. Adapters wrap a concrete backend
/// (HTTP provider today; an on-device model later). Gives the macOS AI path a
/// real seam so resilience policy and request/decode logic can be composed and
/// exercised with a fake, instead of switching over providers inline in the
/// `AIClient` monolith. Mirrors the proven iOS `LLMProvider`.
///
/// Adapters must stay platform-agnostic (Foundation/OSLog/URLSession only — no
/// AppKit) so this layer can move into the shared module later.
protocol LLMProvider: Sendable {
    /// Human-readable name for logs / UI. Mirrors `AIProvider.displayName`.
    var displayName: String { get }
    func process(text: String, systemPrompt: String) async throws -> String
}
