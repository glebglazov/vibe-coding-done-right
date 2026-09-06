import Foundation

/// Hands out the provider that runs a Transcription Model, and keeps every one
/// it has handed out. A model loaded in this process stays loaded until the app
/// is killed (`docs/adr/0016`), so recording with one model, then another, then
/// the first again must return the first provider still holding its compiled
/// CoreML models — a fresh one would pay the cold load a second time, which is
/// the cost a person actually feels.
final class TranscriptionProviderRegistry {

    /// The Transcription Model Library iOS offers, smallest Whisper first,
    /// which is the order someone hunting for one their phone keeps up with
    /// reads in. Not derived from `TranscriptionModel`'s cases: a case existing
    /// is not a claim that this platform has a provider for it.
    static let offeredModels: [TranscriptionModel] = [.parakeetV3] + WhisperCheckpoint.allCases.map(\.model)

    private var providers: [TranscriptionModel: any StreamingTranscriptionProvider] = [:]

    func provider(for model: TranscriptionModel) -> any StreamingTranscriptionProvider {
        if let resident = providers[model] { return resident }
        let provider: any StreamingTranscriptionProvider = switch model {
        case .parakeetV3: ParakeetProvider()
        case .whisperTiny: WhisperProvider(checkpoint: .tiny)
        case .whisperBase: WhisperProvider(checkpoint: .base)
        case .whisperSmall: WhisperProvider(checkpoint: .small)
        case .whisperMedium: WhisperProvider(checkpoint: .medium)
        case .whisperLargeV3: WhisperProvider(checkpoint: .largeV3)
        case .whisperLargeV3Turbo: WhisperProvider(checkpoint: .largeV3Turbo)
        }
        providers[model] = provider
        return provider
    }

    /// Keeps `provider` as the one that runs its model, so a caller that built
    /// its own — a test, or the app handing in an already-warmed Parakeet —
    /// does not end up beside a second provider for the same model.
    func adopt(_ provider: any StreamingTranscriptionProvider) {
        providers[provider.model] = provider
    }
}
