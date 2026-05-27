import Foundation
import OSLog

enum AIClient {
    // MARK: - Constants

    private static let anthropicEndpoint = "https://api.anthropic.com/v1/messages"
    private static let openaiEndpoint = "https://api.openai.com/v1/chat/completions"
    private static let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models"
    private static let defaultAnthropicModel = "claude-haiku-4-5-20251001"
    private static let defaultOpenAIModel = "gpt-4o-mini"
    private static let defaultGeminiModel = "gemini-3.1-flash-lite"
    private static let defaultMaxTokens = 1024
    private static let requestTimeout: TimeInterval = 30

    // MARK: - Public API

    static func process(
        text: String,
        systemPrompt: String,
        provider: AIProvider,
        apiKey: String,
        parameterValues: [String: String] = [:]
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey(provider: provider)
        }

        switch provider {
        case .anthropic:
            return try await callAnthropic(text: text, systemPrompt: systemPrompt, apiKey: apiKey)
        case .openai:
            return try await callOpenAI(text: text, systemPrompt: systemPrompt, apiKey: apiKey)
        case .gemini:
            return try await callGemini(text: text, systemPrompt: systemPrompt, apiKey: apiKey, parameterValues: parameterValues)
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

    // MARK: - Gemini

    private static func callGemini(text: String, systemPrompt: String, apiKey: String, parameterValues: [String: String]) async throws -> String {
        let model = defaultGeminiModel

        var components = URLComponents(string: "\(geminiEndpoint)/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        var body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": text]]]
            ],
            "generationConfig": [
                "maxOutputTokens": defaultMaxTokens
            ]
        ]
        if !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            let errorMessage = parseGeminiError(data: data)
            throw AIClientError.apiError(provider: .gemini, statusCode: statusCode, message: errorMessage)
        }

        return try parseGeminiResponse(data: data)
    }

    private static func parseGeminiResponse(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw AIClientError.invalidResponse(provider: .gemini)
        }
        return text
    }

    private static func parseGeminiError(data: Data) -> String {
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

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider.displayName) API key is not set. Add \(provider.apiKeyVariableName) in Variables."
        case .apiError(let provider, let statusCode, let message):
            "\(provider.displayName) API error (\(statusCode)): \(message)"
        case .invalidResponse(let provider):
            "Invalid response from \(provider.displayName) API"
        }
    }
}
