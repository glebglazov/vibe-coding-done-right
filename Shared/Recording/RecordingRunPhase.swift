import Foundation

nonisolated enum RecordingRunPhase: Equatable, Sendable {
    case arming
    case cancellingArming
    case capturing(since: Date)
    case finalizing
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
        case .cancellingArming?, .finalizing?: .ignore
        }
    }

    static func stopCommand(for phase: RecordingRunPhase?) -> RecordingRunCommand {
        switch command(for: phase) {
        case .start, .ignore: .ignore
        case .stop: .stop
        }
    }
}
