import Foundation

/// Anthropic Messages API adapter. Behavior is identical to the platform
/// `AnthropicProvider` copies it consolidates — same endpoint, model, parse, and
/// error mapping. Stays platform-agnostic (Foundation / URLSession only — no
/// AppKit/UIKit). Phase 1 keeps the default model ID hardcoded; model selection
/// arrives with the Model Catalog in Phase 2.
struct AnthropicAdapter: LLMAdapter {
    let apiKey: String

    var displayName: String { CloudAIBackend.anthropic.displayName }

    private static let endpoint = "https://api.anthropic.com/v1/messages"
    private static let defaultModel = "claude-haiku-4-5-20251001"
    private static let defaultMaxTokens = 1024
    private static let requestTimeout: TimeInterval = 30

    func process(text: String, systemPrompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw CloudAIClientError.missingAPIKey(provider: .anthropic) }

        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = Self.requestTimeout

        let body: [String: Any] = [
            "model": Self.defaultModel,
            "max_tokens": Self.defaultMaxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            let errorMessage = Self.parseError(data: data)
            throw CloudAIClientError.apiError(provider: .anthropic, statusCode: statusCode, message: errorMessage)
        }

        return try Self.parseResponse(data: data)
    }

    private static func parseResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw CloudAIClientError.invalidResponse(provider: .anthropic)
        }
        return text
    }

    private static func parseError(data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return "Unknown error"
        }
        return message
    }
}
