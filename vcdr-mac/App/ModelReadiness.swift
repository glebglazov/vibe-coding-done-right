import Foundation

/// What macOS says about the transcription model. The readiness surfaces
/// switch on this value instead of reading a status string for keywords, so a
/// wait can never be mistaken for a failure by how its text happens to start.
enum ModelReadiness: Equatable {
    /// The model is not usable yet. The label is the shared Model Preparation
    /// Phase wording, heartbeat included.
    case preparing(label: String)
    case ready
    case failed(message: String)
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
        guard phase != .ready else { return .ready }
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

    /// `nil` once the model is ready — the run has nothing left to explain.
    mutating func line(
        for phase: ModelPreparationPhase,
        at now: ContinuousClock.Instant = .now
    ) -> String? {
        guard case .preparing(let label) = narrator.readiness(for: phase, at: now) else { return nil }
        return "\(label) — your recording is safe"
    }
}
