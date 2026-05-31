import Foundation

/// One non-streaming text-enhancement call: text in, system prompt in, enhanced
/// text out (or throw). This is the `LLM Adapter` of the shared LLM Adapter Seam.
/// Cloud HTTP adapters (Anthropic, OpenAI, Gemini) and the `ProviderCascade`
/// conform to it; platform backends such as Apple AFM conform on their own side
/// and are wired in by platform AI Provider Selection — never registered here.
///
/// Adapters stay platform-agnostic (Foundation / URLSession / OSLog only — no
/// AppKit or UIKit) so the seam compiles into every app and extension target.
/// Sendable + existential-friendly, matching the transcription and history store
/// seams already shared across platforms.
protocol LLMAdapter: Sendable {
    /// Human-readable name for logs / UI.
    var displayName: String { get }
    func process(text: String, systemPrompt: String) async throws -> String
}
