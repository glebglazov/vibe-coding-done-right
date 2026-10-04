import Foundation

/// The Mic Presence card's wire state: exactly one face. The not-ready face is
/// not a case here. It comes from the activity's `staleDate`, so iOS can still
/// show it after the app process is gone.
nonisolated enum MicPresenceCardState: Codable, Hashable, Sendable {
    case ready
    /// `cardStops` is false for a run whose stop must come from where it
    /// started, so the face shows no button.
    case arming(cardStops: Bool)
    case capturing(since: Date, cardStops: Bool)
    case finalizing
    case concluded(RunCardOutcome)

    var stopControl: CardStopControl? {
        switch self {
        case .arming(cardStops: true): .cancel
        case .capturing(_, cardStops: true): .stop
        case .arming, .capturing, .ready, .finalizing, .concluded: nil
        }
    }
}

nonisolated enum RunCardOutcome: String, Codable, Hashable, Sendable {
    case transcribed
    case noSpeech
    case failed
}

nonisolated enum CardStopControl: Equatable, Sendable {
    case cancel
    case stop
}
