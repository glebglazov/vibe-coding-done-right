import Foundation

/// What the host source can tell VCDR about the host app.
nonisolated enum HostAppSourceState: Equatable, Sendable {
    /// The private UIKit path is missing on this iOS version.
    case inert
    case observing(latest: HostObservation?)
}

/// The Recording Run as one Host Return attempt sees it.
nonisolated enum HostReturnRunProgress: String, Sendable {
    case arming
    case capturing
    /// The user stopped or cancelled, or the run failed to start.
    case ended
}

/// How one Host Return attempt ended.
nonisolated enum HostReturnOutcome: String, Sendable {
    case returned
    case openFailed
    case hostUnknown
    case apiMissing
    case notCapturing
    case runEnded
}

nonisolated struct HostReturnInputs: Equatable, Sendable {
    let source: HostAppSourceState
    let run: HostReturnRunProgress
    let deadlinePassed: Bool
}

nonisolated enum HostReturnStep: Equatable, Sendable {
    case wait
    case open(HostBundleID)
    case stay(HostReturnOutcome)
}

nonisolated enum HostReturnDecision {
    // MARK: - Constants

    /// Bounds the whole wait for a host and for Capturing, measured from the
    /// deep link's arrival. A measurement target, not a derived value.
    static let deadline: Duration = .milliseconds(2500)
    /// A host seen this long before the deep link still belongs to it: on a
    /// warm launch UIKit can report the host before `onOpenURL` runs.
    static let lookBack: TimeInterval = 5

    // MARK: - Decision

    static func freshHost(in source: HostAppSourceState, arrivedAt: Date) -> HostBundleID? {
        guard case .observing(let latest?) = source,
              latest.observedAt >= arrivedAt.addingTimeInterval(-lookBack)
        else { return nil }
        return latest.host
    }

    /// The app leaves only once audio flows, because starting audio from the
    /// background can fail.
    static func step(for inputs: HostReturnInputs, arrivedAt: Date) -> HostReturnStep {
        if inputs.run == .ended { return .stay(.runEnded) }
        guard case .observing = inputs.source else { return .stay(.apiMissing) }
        guard let host = freshHost(in: inputs.source, arrivedAt: arrivedAt) else {
            return inputs.deadlinePassed ? .stay(.hostUnknown) : .wait
        }
        if inputs.run == .capturing { return .open(host) }
        return inputs.deadlinePassed ? .stay(.notCapturing) : .wait
    }
}
