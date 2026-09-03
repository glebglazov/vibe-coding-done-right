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

protocol TranscriptionProvider: Sendable {
    var name: String { get }
    var isReady: Bool { get async }
    /// What the provider is doing while it gets ready. Every readiness surface
    /// — menu bar, settings badge, the recording pill — words the wait from
    /// this, so none of them has to guess from `isReady` alone.
    var initPhase: ModelPreparationPhase { get async }
    func initialize() async throws
    func transcribe(audioFileURL: URL) async throws -> String
}
