import Foundation
import OSLog

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
    /// Prepares the model: the download, then the load. Preparations are
    /// sequenced across models, and `urgency` is what decides the order — say
    /// whether anything is waiting on this one right now.
    func initialize(urgency: PreparationUrgency) async throws
    /// Transcribes the recording with what this model has been told. A model
    /// that declares no Capability is handed the settings and the Dictionary's
    /// Spelling Hints like any other and reads nothing out of them — declaring
    /// a Capability is what makes a setting or the hints reach a backend at all.
    func transcribe(
        audioFileURL: URL,
        settings: TranscriptionModelSettings,
        spellingHints: SpellingHints
    ) async throws -> String
}

extension TranscriptionProvider {
    var name: String { model.displayName }

    /// Holds a recording that started before the model was ready until it is
    /// (`docs/adr/0006`). A Preparation Failure ends the wait instead: the
    /// model is not coming, and the caller must say so rather than hold the
    /// audio forever.
    func waitUntilReady(pollingEvery interval: Duration) async throws {
        while !(await isReady) {
            if case .failed(let failure) = await initPhase {
                throw TranscriptionError.initializationFailed(failure)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: interval)
        }
    }

    /// Runs a transcription attempt and puts its timing on the record: how
    /// long it took against how long the audio was, and which model this was
    /// — the numbers a person choosing between Whisper sizes needs, worded
    /// identically regardless of which backend ran it. A failure is logged at
    /// `.error` with its own wording, so it never reads as a slow success.
    func loggingTranscriptionTiming(
        audioFileURL: URL,
        body: () async throws -> String
    ) async throws -> String {
        let audioDuration = TranscriptionTiming.audioDuration(of: audioFileURL)
        let start = ContinuousClock.now
        do {
            let text = try await body()
            let line = TranscriptionTiming.succeededLine(
                model: self.model,
                audioDuration: audioDuration,
                elapsed: start.duration(to: .now),
                characterCount: text.count
            )
            Logger.transcription.info("\(line)")
            return text
        } catch {
            let line = TranscriptionTiming.failedLine(
                model: self.model,
                audioDuration: audioDuration,
                elapsed: start.duration(to: .now),
                error: error
            )
            Logger.transcription.error("\(line)")
            throw error
        }
    }
}
