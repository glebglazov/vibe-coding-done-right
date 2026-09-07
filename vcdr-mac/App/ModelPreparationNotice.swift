import Foundation

extension ModelReadiness {
    /// The readiness a preparation attempt that threw leaves behind. The
    /// provider classifies what it catches; anything else escaping
    /// initialization is classified here so the raw error never reaches a view
    /// — and only this platform knows what its own `TranscriptionError` carries.
    static func failed(from error: Error) -> ModelReadiness {
        if let error = error as? TranscriptionError,
           case .initializationFailed(let failure) = error {
            return .failed(failure)
        }
        return .failed(PreparationFailure(error: error))
    }
}

/// What the capture flow says about a model that is not ready yet. It is the
/// readiness line plus the one thing this moment needs and the menu bar does
/// not: that the audio — being spoken, or already spoken and held — is not
/// lost while the wait runs.
struct ModelPreparationNotice {
    private var narrator: ModelPreparationNarrator

    init(now: ContinuousClock.Instant = .now) {
        narrator = ModelPreparationNarrator(now: now)
    }

    /// `nil` once the model is ready — the run has nothing left to explain. A
    /// Preparation Failure drops the assurance: the wait is over and the audio
    /// this run holds will not be transcribed, so promising it is safe would lie.
    mutating func line(
        for phase: ModelPreparationPhase,
        at now: ContinuousClock.Instant = .now
    ) -> String? {
        switch narrator.readiness(for: phase, at: now) {
        case .ready: nil
        case .preparing(let label): "\(label) — your recording is safe"
        case .failed(let failure): failure.message
        }
    }
}
