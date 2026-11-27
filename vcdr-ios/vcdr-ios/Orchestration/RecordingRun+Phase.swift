import Foundation

extension RecordingRun {
    /// Where the run is in its lifecycle. `ended` is absorbing: no event
    /// leaves it, so a late callback cannot change what the run decided.
    enum Phase: Equatable {
        case arming
        case capturing(since: Date)
        case finalizing
        case ended(RecordingRunTerminalState)

        /// The phase Mic Presence and the toggles read; nil once ended.
        var live: RecordingRunPhase? {
            switch self {
            case .arming: .arming
            case .capturing(let since): .capturing(since: since)
            case .finalizing: .finalizing
            case .ended: nil
            }
        }
    }
}
