import Foundation

/// The phase of the one active Recording Run.
nonisolated enum RecordingRunPhase: Equatable, Sendable {
    /// Record intent acknowledged, audio engine warming, no audio yet.
    case arming
    /// A stop landed during Arming. The start path that still waits for the
    /// engine tears the run down. The run still blocks a new start, because a
    /// second `startCapture` would race the first one.
    case cancellingArming
    /// Audio is flowing. `since` starts the card's running timer.
    case capturing(since: Date)
    /// Capture ended. Transcription and Completion Delivery are pending, and
    /// nothing can abort them.
    case finalizing
}

/// What a trigger does to the active Recording Run.
nonisolated enum RecordingRunCommand: Equatable, Sendable {
    case start
    case stop
    case ignore
}

/// The toggle and stop contract every trigger follows, as one table.
nonisolated enum RecordingToggle {
    /// "Toggle Recording": start with no run, stop during Arming (a
    /// cancellation) or Capturing, and ignore a press while a cancel or a
    /// Finalizing is already in flight.
    static func command(for phase: RecordingRunPhase?) -> RecordingRunCommand {
        switch phase {
        case nil: .start
        case .arming?, .capturing?: .stop
        case .cancellingArming?, .finalizing?: .ignore
        }
    }

    /// Every stop-only trigger (the card's Stop button, a keyboard stop, the
    /// stop deep link). A stop never begins a run.
    static func stopCommand(for phase: RecordingRunPhase?) -> RecordingRunCommand {
        switch command(for: phase) {
        case .start, .ignore: .ignore
        case .stop: .stop
        }
    }
}
