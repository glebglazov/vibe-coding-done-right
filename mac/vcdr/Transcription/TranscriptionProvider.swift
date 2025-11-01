import Foundation

/// Protocol defining the interface for speech-to-text transcription providers
protocol TranscriptionProvider: Identifiable {
    /// Unique identifier for the provider
    var id: UUID { get }

    /// Display name of the provider (e.g., "WhisperKit", "Deepgram", "AssemblyAI")
    var name: String { get }

    /// Check if the provider is available and ready to use
    var isAvailable: Bool { get async }

    /// Initialize the transcription provider (download models, setup, etc.)
    func initialize() async throws

    /// Transcribe audio from a file
    /// - Parameter audioFileURL: URL to the audio file to transcribe
    /// - Returns: The transcribed text
    func transcribe(audioFileURL: URL) async throws -> String
}

/// Errors that can occur during transcription
enum TranscriptionError: LocalizedError {
    case providerUnavailable
    case initializationFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return "Transcription provider is not available"
        case .initializationFailed(let message):
            return "Failed to initialize transcription: \(message)"
        case .transcriptionFailed(let message):
            return "Failed to transcribe audio: \(message)"
        }
    }
}
