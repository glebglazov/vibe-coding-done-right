import Foundation

/// What macOS says about the transcription model. The readiness surfaces
/// switch on this value instead of reading a status string for keywords, so a
/// wait can never be mistaken for a failure by how its text happens to start.
enum ModelReadiness: Equatable {
    /// The model is not usable yet. The label is the shared Model Preparation
    /// Phase wording, heartbeat included.
    case preparing(label: String)
    case ready
    /// Preparation stopped. The failure is the one the provider classified at
    /// the point it gave up, so no surface has to read the backend's words.
    case failed(PreparationFailure)
}

extension ModelReadiness {
    /// The readiness a preparation attempt that threw leaves behind. The
    /// provider classifies what it catches; anything else escaping
    /// initialization is classified here so the raw error never reaches a view.
    static func failed(from error: Error) -> ModelReadiness {
        if let error = error as? TranscriptionError,
           case .initializationFailed(let failure) = error {
            return .failed(failure)
        }
        return .failed(PreparationFailure(error: error))
    }
}

/// Turns the Model Preparation Phase reported by the transcription provider
/// into the line every macOS readiness surface shows. It owns the clock the
/// Preparation Heartbeat counts: the clock restarts on each phase change, so
/// the heartbeat measures the current wait rather than the whole launch.
struct ModelPreparationNarrator {
    private var currentPhase: ModelPreparationPhase?
    private var phaseStart: ContinuousClock.Instant

    init(now: ContinuousClock.Instant = .now) {
        phaseStart = now
    }

    mutating func readiness(
        for phase: ModelPreparationPhase,
        at now: ContinuousClock.Instant = .now
    ) -> ModelReadiness {
        if phase != currentPhase {
            currentPhase = phase
            phaseStart = now
        }
        switch phase {
        case .ready: return .ready
        case .failed(let failure): return .failed(failure)
        default: break
        }
        let elapsedSeconds = Int((now - phaseStart).components.seconds)
        return .preparing(label: phase.label(elapsedSeconds: elapsedSeconds))
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
