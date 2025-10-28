import Foundation

/// LLM provider using Ollama for local model inference
/// Requires Ollama to be installed and running (ollama.com)
class OllamaProvider: LLMProvider {
    let id = UUID()
    let name = "Ollama"
    let requiresAPIKey = false

    /// The model to use (e.g., "llama3.2:3b", "qwen2.5-coder:7b", "gemma2:9b")
    var modelName: String

    /// Base URL for Ollama API (default: http://localhost:11434)
    var baseURL: String

    init(modelName: String = "llama3.2:3b", baseURL: String = "http://localhost:11434") {
        self.modelName = modelName
        self.baseURL = baseURL
    }

    var isAvailable: Bool {
        get async {
            // Check if Ollama is running by hitting the /api/tags endpoint
            guard let url = URL(string: "\(baseURL)/api/tags") else {
                return false
            }

            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    return httpResponse.statusCode == 200
                }
                return false
            } catch {
                print("⚠️ Ollama not available: \(error.localizedDescription)")
                return false
            }
        }
    }

    func generate(prompt: String, systemPrompt: String?) async throws -> String {
        // Log what we're sending to the AI
        print("🤖 ==================== Ollama Request ====================")
        print("📦 Model: \(modelName)")
        if let systemPrompt = systemPrompt {
            print("📋 System Prompt:")
            print(systemPrompt)
            print("---")
        }
        print("💬 User Prompt:")
        print(prompt)
        print("===========================================================")

        // Check availability
        let available = await isAvailable
        guard available else {
            throw OllamaError.notRunning
        }

        // Construct the API request
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build the request body
        var requestBody: [String: Any] = [
            "model": modelName,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.7,
                "top_p": 0.9
            ]
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
            throw OllamaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw OllamaError.modelNotFound(modelName)
            }
            throw OllamaError.httpError(httpResponse.statusCode)
        }

        // Parse the JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        // Log the response
        print("🤖 ==================== Ollama Response ====================")
        print(responseText)
        print("============================================================")

        return responseText
    }
}

/// Errors specific to Ollama provider
enum OllamaError: LocalizedError {
    case notRunning
    case invalidURL
    case invalidResponse
    case modelNotFound(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama is not running. Please start Ollama: 'ollama serve'"
        case .invalidURL:
            return "Invalid Ollama URL"
        case .invalidResponse:
            return "Received invalid response from Ollama"
        case .modelNotFound(let model):
            return "Model '\(model)' not found. Pull it with: 'ollama pull \(model)'"
        case .httpError(let code):
            return "Ollama HTTP error: \(code)"
        }
    }
}
