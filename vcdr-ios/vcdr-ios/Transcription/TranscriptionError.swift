import Foundation

enum TranscriptionError: LocalizedError {
    case providerUnavailable
    case initializationFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            "Transcription provider is not available"
        case .initializationFailed(let message):
            "Failed to initialize transcription: \(message)"
        case .transcriptionFailed(let message):
            "Failed to transcribe audio: \(message)"
        }
    }
}
