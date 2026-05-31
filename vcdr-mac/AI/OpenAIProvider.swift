import Foundation

/// OpenAI Chat Completions adapter. Behavior moved verbatim from
/// `AIClient.callOpenAI` — same endpoint, model, parse, and error mapping.
/// Stays platform-agnostic (Foundation/URLSession only — no AppKit) and mirrors
/// the proven iOS `OpenAIProvider`.
struct OpenAIProvider: LLMAdapter {
    let apiKey: String

    var displayName: String { AIProvider.openai.displayName }

    private static let endpoint = "https://api.openai.com/v1/chat/completions"
    private static let defaultModel = "gpt-4o-mini"
    private static let defaultMaxTokens = 1024
    private static let requestTimeout: TimeInterval = 30

    func process(text: String, systemPrompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw CloudAIClientError.missingAPIKey(provider: .openai) }

        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.requestTimeout

        let body: [String: Any] = [
            "model": Self.defaultModel,
            "max_tokens": Self.defaultMaxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            let errorMessage = Self.parseError(data: data)
            throw CloudAIClientError.apiError(provider: .openai, statusCode: statusCode, message: errorMessage)
        }

        return try Self.parseResponse(data: data)
    }

    private static func parseResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CloudAIClientError.invalidResponse(provider: .openai)
        }
        return content
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
