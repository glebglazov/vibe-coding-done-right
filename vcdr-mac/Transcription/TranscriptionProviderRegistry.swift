import Foundation

/// Hands out the provider that runs a Transcription Model, and keeps every one
/// it has handed out. A model loaded in this process stays loaded until quit
/// (`docs/adr/0016`), so switching the Default away and back must return the
/// same provider, still holding its compiled CoreML models — a fresh one would
/// pay the cold load again, which is the cost the user actually feels.
final class TranscriptionProviderRegistry {

    /// The Transcription Model Library this platform offers. macOS transcribes a
    /// finished recording, which is the path all of these drive; iOS drives a
    /// live view and offers the same models through it (`docs/adr/0021`). Not
    /// derived from `TranscriptionModel`'s cases, because a case existing is
    /// not a claim that this platform can run it — the Whispers come from the
    /// checkpoints this platform has a provider for, smallest first, which is
    /// the order someone hunting for one their Mac keeps up with reads in.
    static let offeredModels: [TranscriptionModel] = [.parakeetUltra] + WhisperCheckpoint.allCases.map(\.model)

    private var providers: [TranscriptionModel: any TranscriptionProvider] = [:]

    /// The one queue every provider handed out prepares through. It lives here
    /// because this is the only place that sees all of them, and sequencing
    /// preparations is only possible from somewhere that does.
    private let preparationQueue = ModelPreparationQueue()

    func provider(for model: TranscriptionModel) -> any TranscriptionProvider {
        if let resident = providers[model] { return resident }
        let provider: any TranscriptionProvider = switch model {
        case .parakeetUltra: ParakeetProvider(preparationQueue: preparationQueue)
        case .whisperTiny: WhisperProvider(checkpoint: .tiny, preparationQueue: preparationQueue)
        case .whisperBase: WhisperProvider(checkpoint: .base, preparationQueue: preparationQueue)
        case .whisperSmall: WhisperProvider(checkpoint: .small, preparationQueue: preparationQueue)
        case .whisperMedium: WhisperProvider(checkpoint: .medium, preparationQueue: preparationQueue)
        case .whisperLargeV3: WhisperProvider(checkpoint: .largeV3, preparationQueue: preparationQueue)
        case .whisperLargeV3Turbo: WhisperProvider(checkpoint: .largeV3Turbo, preparationQueue: preparationQueue)
        }
        providers[model] = provider
        return provider
    }
}
