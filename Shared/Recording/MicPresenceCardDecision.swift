import Foundation

/// What the Recording Run contributes to Mic Presence. The coordinator is its
/// only writer.
nonisolated enum MicPresenceRun: Equatable, Sendable {
    case active(origin: RecordingRunOrigin, phase: RecordingRunPhase)
    /// The run ended in an outcome worth announcing. The face lasts until
    /// `until`, and after that the run no longer counts.
    case concluded(RunCardOutcome, until: Date)
}

/// What ActivityKit should hold right now.
nonisolated enum MicPresenceCardDecision: Equatable, Sendable {
    case hidden
    /// A live card on this face, kept fresh by renewing its `staleDate`.
    case live(MicPresenceCardState)
    /// A final face, ended with a dismissal at `dismissAt`. Only an outcome is
    /// frozen this way: "Copied" cannot become false later, and a readiness
    /// claim can.
    case concluding(MicPresenceCardState, dismissAt: Date)
}

nonisolated enum MicPresenceCardPolicy {
    /// How long an outcome face stays on the card.
    static let concludedDwell: TimeInterval = 4

    /// Merges three facts, each with one writer: In-Place Reachability (the
    /// Hot Mic Session), whether VCDR is on screen (the scene), and the
    /// Recording Run (the coordinator).
    static func decide(
        reachable: Bool,
        foreground: Bool,
        run: MicPresenceRun?,
        now: Date
    ) -> MicPresenceCardDecision {
        if case .active(let origin, let phase) = run,
           origin.keepsCardInForeground,
           let face = recordingFace(for: phase) {
            return .live(face)
        }
        guard !foreground else { return .hidden }

        switch run {
        case .active(_, .arming):
            return .live(.arming)
        case .active(_, .capturing(let since)):
            return .live(.capturing(since: since))
        case .active(_, .finalizing):
            return .live(.finalizing)
        case .concluded(let outcome, let until) where now < until:
            return reachable
                ? .live(.concluded(outcome))
                : .concluding(.concluded(outcome), dismissAt: until)
        case .active(_, .cancellingArming), .concluded, nil:
            return reachable ? .live(.ready) : .hidden
        }
    }

    private static func recordingFace(for phase: RecordingRunPhase) -> MicPresenceCardState? {
        switch phase {
        case .arming: .arming
        case .capturing(let since): .capturing(since: since)
        case .cancellingArming, .finalizing: nil
        }
    }
}
