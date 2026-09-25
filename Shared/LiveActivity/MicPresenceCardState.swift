import Foundation

/// The Mic Presence card's wire state: exactly one face. The not-ready face is
/// not a case here. It comes from the activity's `staleDate`, so iOS can still
/// show it after the app process is gone.
nonisolated enum MicPresenceCardState: Codable, Hashable, Sendable {
    case ready
    case arming
    case capturing(since: Date)
    case finalizing
    case concluded(RunCardOutcome)

    var stopControl: CardStopControl? {
        switch self {
        case .arming: .cancel
        case .capturing: .stop
        case .ready, .finalizing, .concluded: nil
        }
    }
}

nonisolated enum RunCardOutcome: String, Codable, Hashable, Sendable {
    case copied
    case noSpeech
    case failed
}

nonisolated enum CardStopControl: Equatable, Sendable {
    case cancel
    case stop
}
