import Foundation

nonisolated enum MicPresenceRun: Equatable, Sendable {
    case active(origin: RecordingRunOrigin, phase: RecordingRunPhase)
    case concluded(RunCardOutcome, until: Date)
}

nonisolated enum MicPresenceCardDecision: Equatable, Sendable {
    case hidden
    case live(MicPresenceCardState)
    case concluding(MicPresenceCardState, dismissAt: Date)
}

nonisolated enum MicPresenceCardPolicy {
    static let concludedDwell: TimeInterval = 4

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
