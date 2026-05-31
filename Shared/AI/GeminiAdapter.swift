import Foundation

/// Google Gemini generateContent API adapter. Behavior is identical to the
/// platform `GeminiProvider` copies it consolidates — same endpoint, model,
/// parse, and error mapping, including omitting `systemInstruction` when the
/// system prompt is empty. Stays platform-agnostic (Foundation / URLSession only
/// — no AppKit/UIKit). Phase 1 keeps the default model ID hardcoded.
struct GeminiAdapter: LLMAdapter {
    let apiKey: String

    var displayName: String { CloudAIBackend.gemini.displayName }

    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"
    private static let defaultModel = "gemini-3.1-flash-lite"
    private static let defaultMaxTokens = 1024
    private static let requestTimeout: TimeInterval = 30

    func process(text: String, systemPrompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw CloudAIClientError.missingAPIKey(provider: .gemini) }

        let model = Self.defaultModel
        var components = URLComponents(string: "\(Self.endpoint)/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.requestTimeout

        var body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": text]]]
            ],
            "generationConfig": [
                "maxOutputTokens": Self.defaultMaxTokens
            ]
        ]
        if !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            let errorMessage = Self.parseError(data: data)
            throw CloudAIClientError.apiError(provider: .gemini, statusCode: statusCode, message: errorMessage)
        }

        return try Self.parseResponse(data: data)
    }

    private static func parseResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw CloudAIClientError.invalidResponse(provider: .gemini)
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
