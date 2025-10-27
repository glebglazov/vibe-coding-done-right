import Foundation
import FoundationModels

/// LLM provider using Apple's on-device Foundation Models
class FoundationModelsProvider: LLMProvider {
    let id = UUID()
    let name = "Apple Foundation Models"
    let requiresAPIKey = false

    private let model = SystemLanguageModel.default

    var isAvailable: Bool {
        get async {
            switch model.availability {
            case .available:
                return true
            default:
                return false
            }
        }
    }

    func generate(prompt: String, systemPrompt: String?) async throws -> String {
        // Log what we're sending to the AI
        print("🤖 ==================== AI Request ====================")
        if let systemPrompt = systemPrompt {
            print("📋 System Prompt:")
            print(systemPrompt)
            print("---")
        }
        print("💬 User Prompt:")
        print(prompt)
        print("======================================================")

        // Check availability first and provide detailed error
        let availabilityStatus = model.availability
        
        switch availabilityStatus {
        case .available:
            break
        default:
            // Get string representation of availability status
            let statusString = String(describing: availabilityStatus)
            throw FoundationModelsError.unavailable(statusString)
        }

        // Create session with optional system instructions
        let session: LanguageModelSession

        if let systemPrompt = systemPrompt {
            session = LanguageModelSession {
                systemPrompt
            }
        } else {
            session = LanguageModelSession()
        }

        // Prewarm the session for better performance
        try await session.prewarm()

        // Generate response
        let response = try await session.respond(to: prompt)

        // Log the response
        print("🤖 ==================== AI Response ====================")
        print(response.content)
        print("=======================================================")

        return response.content
    }
}

/// Errors specific to Foundation Models provider
enum FoundationModelsError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            // Parse the reason string to provide helpful messages
            if reason.contains("appleIntelligenceNotEnabled") {
                return "Apple Intelligence is not enabled. Please enable it in System Settings > Apple Intelligence & Siri."
            } else if reason.contains("deviceNotEligible") {
                return "Your device doesn't support Apple Intelligence. Requires Apple Silicon Mac with sufficient RAM."
            } else if reason.contains("unsupportedLanguage") {
                return "Apple Intelligence doesn't support the current system language. Switch to a supported language in System Settings."
            } else {
                return "Apple Intelligence is unavailable: \(reason). Please check System Settings > Apple Intelligence & Siri."
            }
        }
    }
}
