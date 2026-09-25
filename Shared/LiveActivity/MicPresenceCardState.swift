import Foundation

/// The Mic Presence card's wire state: exactly one face. The not-ready face is
/// not a case here. It comes from the activity's `staleDate`, so iOS can still
/// show it after the app process is gone.
nonisolated enum MicPresenceCardState: Codable, Hashable, Sendable {
    /// Hot Mic Session warm and reachable, no Recording Run.
    case ready
    /// Arming. No timer, because nothing is captured yet.
    case arming
    /// Capturing, with a timer that runs from `since`.
    case capturing(since: Date)
    case finalizing
    /// A short outcome face for a run whose result has no other surface.
    case concluded(RunCardOutcome)

    /// Stopping during Arming is a cancellation, so the button says so.
    var stopControl: CardStopControl? {
        switch self {
        case .arming: .cancel
        case .capturing: .stop
        case .ready, .finalizing, .concluded: nil
        }
    }
}

nonisolated enum RunCardOutcome: String, Codable, Hashable, Sendable {
    /// The final text is on the clipboard.
    case copied
    /// Empty Result. Nothing was copied.
    case noSpeech
    /// Processing Failure. Nothing was copied.
    case failed
}

nonisolated enum CardStopControl: Equatable, Sendable {
    case cancel
    case stop
}
