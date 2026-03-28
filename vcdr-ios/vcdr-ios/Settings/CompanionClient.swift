import Foundation

/// HTTP client for the VCDR companion server.
enum CompanionClient {
    // MARK: - Constants
    private static let requestTimeout: TimeInterval = 30
    private static let integrationMode = "dictation"

    struct ProcessResponse: Decodable {
        let text: String
    }

    struct ErrorResponse: Decodable {
        let error: String
    }

    /// Sends text to the companion server for LLM-powered post-processing.
    /// - Parameters:
    ///   - text: The raw transcribed text.
    ///   - host: Server hostname (e.g. "vcdr-server.glebglazov.me").
    ///   - apiKey: Bearer token for authentication.
    /// - Returns: The processed text from the server.
    static func process(text: String, host: String, apiKey: String) async throws -> String {
        let scheme = host.contains("localhost") || host.contains("127.0.0.1") ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(host)/v1/process") else {
            throw CompanionError.invalidHost(host)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let body: [String: Any] = [
            "integration_mode": integrationMode,
            "text": "<dictation>\(text)</dictation>",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw CompanionError.serverError(errorResp.error)
            }
            throw CompanionError.httpError(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(ProcessResponse.self, from: data)
        return result.text
    }
}

enum CompanionError: LocalizedError {
    case invalidHost(String)
    case invalidResponse
    case serverError(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidHost(let host): "Invalid server host: \(host)"
        case .invalidResponse: "Invalid response from server"
        case .serverError(let message): "Server error: \(message)"
        case .httpError(let code): "HTTP error \(code)"
        }
    }
}
