import Foundation

/// Hands out the provider that runs a Transcription Model, and keeps every one
/// it has handed out. A model loaded in this process stays loaded until quit
/// (`docs/adr/0016`), so switching the Default away and back must return the
/// same provider, still holding its compiled CoreML models — a fresh one would
/// pay the cold load again, which is the cost the user actually feels.
final class TranscriptionProviderRegistry {

    /// The Transcription Model Library this platform offers. macOS transcribes a
    /// finished recording, which is the path all of these drive; iOS drives a
    /// live view and so offers only Parakeet (`docs/adr/0018`). Not derived
    /// from `TranscriptionModel`'s cases, because a case existing is not a
    /// claim that this platform can run it — the Whispers come from the
    /// checkpoints this platform has a provider for, smallest first, which is
    /// the order someone hunting for one their Mac keeps up with reads in.
    static let offeredModels: [TranscriptionModel] = [.parakeetV3] + WhisperCheckpoint.allCases.map(\.model)

    /// The families those models belong to, each named once and in the order
    /// the Library offers them. What a family is told is one answer for all of
    /// its members, so a screen that renders settings renders one section per
    /// family rather than one per model.
    static let offeredFamilies: [TranscriptionModelFamily] = offeredModels.reduce(into: []) { families, model in
        guard !families.contains(model.family) else { return }
        families.append(model.family)
    }

    private var providers: [TranscriptionModel: any TranscriptionProvider] = [:]

    func provider(for model: TranscriptionModel) -> any TranscriptionProvider {
        if let resident = providers[model] { return resident }
        let provider: any TranscriptionProvider = switch model {
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
}
