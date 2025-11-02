import Foundation

/// LLM provider using Anthropic's Claude API
class AnthropicProvider: LLMProvider {
    let id: UUID
    let name: String
    let requiresAPIKey = true

    /// The model to use (e.g., "claude-sonnet-4-5-20250929")
    var modelName: String

    /// API key from global settings
    private var apiKey: String {
        GlobalProviderSettingsStorage.shared.loadAnthropicSettings().apiKey
    }

    init(id: UUID = UUID(), name: String = "Anthropic", modelName: String = "claude-sonnet-4-5-20250929") {
        self.id = id
        self.name = name
        self.modelName = modelName
    }

    var isAvailable: Bool {
        get async {
            // Check if API key is configured
            let key = apiKey
            return !key.isEmpty && key.hasPrefix("sk-ant-")
        }
    }

    func generate(prompt: String, systemPrompt: String?) async throws -> String {
        // Log what we're sending to the AI
        print("🤖 ==================== Anthropic Request ====================")
        print("📦 Model: \(modelName)")
        if let systemPrompt = systemPrompt {
            print("📋 System Prompt:")
            print(systemPrompt)
            print("---")
        }
        print("💬 User Prompt:")
        print(prompt)
        print("============================================================")

        // Check if API key is configured
        guard !apiKey.isEmpty else {
            throw AnthropicError.missingAPIKey
        }

        guard apiKey.hasPrefix("sk-ant-") else {
            throw AnthropicError.invalidAPIKey
        }

        // Construct the API request
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AnthropicError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Build the request body
        var messages: [[String: Any]] = [
            [
                "role": "user",
                "content": prompt
            ]
        ]

        var requestBody: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "max_tokens": 4096
        ]

        // Add system prompt if provided
        if let systemPrompt = systemPrompt {
            requestBody["system"] = systemPrompt
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Make the request
        let (data, response) = try await URLSession.shared.data(for: request)

        // Check response status
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Try to parse error message
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AnthropicError.apiError(message)
            }
            throw AnthropicError.httpError(httpResponse.statusCode)
        }

        // Parse the JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let responseText = firstContent["text"] as? String else {
            throw AnthropicError.invalidResponse
        }

        // Log the response
        print("🤖 ==================== Anthropic Response ====================")
        print(responseText)
        print("==============================================================")

        return responseText
    }
}

/// Errors specific to Anthropic provider
enum AnthropicError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case invalidURL
    case invalidResponse
    case apiError(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key not configured. Please add your API key in Settings > Providers."
        case .invalidAPIKey:
            return "Invalid Anthropic API key format. API keys should start with 'sk-ant-'."
        case .invalidURL:
            return "Invalid Anthropic API URL"
        case .invalidResponse:
            return "Received invalid response from Anthropic API"
        case .apiError(let message):
            return "Anthropic API error: \(message)"
        case .httpError(let code):
            return "Anthropic HTTP error: \(code)"
        }
    }
}
