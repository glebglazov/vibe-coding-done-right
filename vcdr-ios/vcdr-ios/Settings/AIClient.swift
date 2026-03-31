import Foundation
import OSLog

enum AIClient {
    // MARK: - Constants

    private static let anthropicEndpoint = "https://api.anthropic.com/v1/messages"
    private static let openaiEndpoint = "https://api.openai.com/v1/chat/completions"
    private static let defaultAnthropicModel = "claude-haiku-4-5-20251001"
    private static let defaultOpenAIModel = "gpt-4o-mini"
    private static let defaultMaxTokens = 1024
    private static let requestTimeout: TimeInterval = 30

    // MARK: - Public API

    static func process(
        text: String,
        systemPrompt: String,
        provider: AIProvider,
        apiKey: String
    ) async throws -> String {
        switch provider {
        case .anthropic:
            guard !apiKey.isEmpty else { throw AIClientError.missingAPIKey(provider: provider) }
            return try await callAnthropic(text: text, systemPrompt: systemPrompt, apiKey: apiKey)
        case .openai:
            guard !apiKey.isEmpty else { throw AIClientError.missingAPIKey(provider: provider) }
            return try await callOpenAI(text: text, systemPrompt: systemPrompt, apiKey: apiKey)
        case .apple:
            return try await AFMClient.process(text: text, systemPrompt: systemPrompt)
        }
    }

    // MARK: - Anthropic

    private static func callAnthropic(text: String, systemPrompt: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: anthropicEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = requestTimeout

        let body: [String: Any] = [
            "model": defaultAnthropicModel,
            "max_tokens": defaultMaxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            let errorMessage = parseAnthropicError(data: data)
            throw AIClientError.apiError(provider: .anthropic, statusCode: statusCode, message: errorMessage)
        }

        return try parseAnthropicResponse(data: data)
    }

    private static func parseAnthropicResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIClientError.invalidResponse(provider: .anthropic)
        }
        return text
    }

    private static func parseAnthropicError(data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return "Unknown error"
        }
        return message
    }

    // MARK: - OpenAI

    private static func callOpenAI(text: String, systemPrompt: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: openaiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let body: [String: Any] = [
            "model": defaultOpenAIModel,
            "max_tokens": defaultMaxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            let errorMessage = parseOpenAIError(data: data)
            throw AIClientError.apiError(provider: .openai, statusCode: statusCode, message: errorMessage)
        }

        return try parseOpenAIResponse(data: data)
    }

    private static func parseOpenAIResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIClientError.invalidResponse(provider: .openai)
        }
        return content
    }

    private static func parseOpenAIError(data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return "Unknown error"
        }
        return message
    }
}

// MARK: - Errors

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
