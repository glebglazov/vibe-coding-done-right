import Foundation

/// Hands out the provider that runs a Transcription Model, and keeps every one
/// it has handed out. A model loaded in this process stays loaded until quit
/// (`docs/adr/0016`), so switching the Default away and back must return the
/// same provider, still holding its compiled CoreML models — a fresh one would
/// pay the cold load again, which is the cost the user actually feels.
final class TranscriptionProviderRegistry {

    /// The Transcription Model Library this platform offers. macOS transcribes a
    /// finished recording, which is the path both of these drive; iOS drives a
    /// live view and so offers only Parakeet (`docs/adr/0018`). Written out
    /// rather than derived from the enum's cases, because a case existing is
    /// not a claim that this platform can run it.
    static let offeredModels: [TranscriptionModel] = [.parakeetV3, .whisperLargeV3Turbo]

    private var providers: [TranscriptionModel: any TranscriptionProvider] = [:]

    func provider(for model: TranscriptionModel) -> any TranscriptionProvider {
        if let resident = providers[model] { return resident }
        let provider: any TranscriptionProvider = switch model {
        case .parakeetV3: ParakeetProvider()
        case .whisperLargeV3Turbo: WhisperProvider()
        }
        providers[model] = provider
        return provider
    }
}
