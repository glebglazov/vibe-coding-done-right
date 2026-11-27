import Foundation

nonisolated enum RecordingRunPhase: Equatable, Sendable {
    case arming
    case capturing(since: Date)
    case finalizing

    /// AI Prompt Mode and Text Style are fixed while the run listens: they
    /// unlock once capture ends.
    var locksOutputChoices: Bool {
        switch self {
        case .arming, .capturing: true
        case .finalizing: false
        }
    }
}

nonisolated enum RecordingRunCommand: Equatable, Sendable {
    case start
    case stop
    case ignore
}

nonisolated enum RecordingToggle {
    static func command(for phase: RecordingRunPhase?) -> RecordingRunCommand {
        switch phase {
        case nil: .start
        case .arming?, .capturing?: .stop
        case .finalizing?: .ignore
        }
    }

    static func stopCommand(for phase: RecordingRunPhase?) -> RecordingRunCommand {
        switch command(for: phase) {
        case .start, .ignore: .ignore
        case .stop: .stop
        }
    }
}
