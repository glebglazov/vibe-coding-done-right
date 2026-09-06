import Foundation

enum TranscriptionError: LocalizedError {
    case providerUnavailable
    case initializationFailed(PreparationFailure)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            "Transcription provider is not available"
        case .initializationFailed(let failure):
            failure.message
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
    /// What the provider is doing while it gets ready. Every readiness surface
    /// — menu bar, settings badge, the recording pill — words the wait from
    /// this, so none of them has to guess from `isReady` alone.
    var initPhase: ModelPreparationPhase { get async }
    /// The directory inside the owned model root this model's files occupy.
    /// Neither backend offers an inventory or a delete, so the Library sizes
    /// and removes an install through the directory — and only the provider
    /// knows the layout its own SDK chose under the root.
    nonisolated var installedDirectory: URL { get }
    /// Whether this model's files are on disk and complete enough to load,
    /// answered by the SDK that wrote them wherever one can say. A model can be
    /// installed without being loaded: preparing it is what loads it.
    nonisolated var isInstalled: Bool { get }
    /// How much of the download is done, or nil for a backend that reports no
    /// progress at all. Only the Library shows it; the menu bar and the
    /// recording pill collapse the whole wait into one label.
    var downloadProgress: Double? { get async }
    /// Whether this Mac can install this model. A backend that publishes a
    /// per-device support table has to be asked over the network, so this both
    /// throws and takes time — the Library treats not knowing as its own state
    /// rather than as "no".
    func isInstallableOnThisDevice() async throws -> Bool
    func initialize() async throws
    /// Transcribes the recording with what this model has been told. A model
    /// that declares no Capability is handed the settings like any other and
    /// reads nothing out of them — declaring a Capability is what makes a
    /// setting reach a backend at all.
    func transcribe(audioFileURL: URL, settings: TranscriptionModelSettings) async throws -> String
}

extension TranscriptionProvider {
    var name: String { model.displayName }
}
