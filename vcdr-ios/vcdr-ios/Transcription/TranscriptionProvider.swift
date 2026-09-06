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
    /// Which Transcription Model this provider runs, so a caller can key
    /// settings and Library membership by it rather than by its wording.
    var model: TranscriptionModel { get }
    var name: String { get }
    var isReady: Bool { get async }
    func initialize() async throws
    func transcribe(audioFileURL: URL) async throws -> String
}

extension TranscriptionProvider {
    var name: String { model.displayName }
}
