import Foundation

/// One call in the OpenAI Chat Completions wire format, which OpenAI and
/// OpenRouter both speak: the request shape, the success decode and the error
/// decode. The adapters that use it say only where to send it, which model to
/// name, and which backend a failure is reported under.
struct ChatCompletionsClient: Sendable {
    let backend: CloudAIBackend
    let endpoint: URL
    let model: String

    // MARK: - Constants

    private static let defaultMaxTokens = 1024
    private static let requestTimeout: TimeInterval = 30

    func process(apiKey: String, text: String, systemPrompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw CloudAIClientError.missingAPIKey(provider: backend) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.requestTimeout

        let body: [String: Any] = [
            "model": model,
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
            throw CloudAIClientError.apiError(provider: backend, statusCode: statusCode, message: errorMessage)
        }

        return try parseResponse(data: data)
    }

    private func parseResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CloudAIClientError.invalidResponse(provider: backend)
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
