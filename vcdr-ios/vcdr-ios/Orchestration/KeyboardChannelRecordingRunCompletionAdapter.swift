import Foundation
import OSLog

/// Every wire value a Recording Run publishes comes from here: its progress
/// and its terminal state, each under the run's own ID.
@MainActor
final class KeyboardChannelRecordingRunCompletionAdapter: RecordingRunCompletionAdapter {
    private let wire: KeyboardWirePublisher
    private let run: RunID
    private let origin: RecordingRunOrigin

    init(wire: KeyboardWirePublisher, run: RunID, origin: RecordingRunOrigin) {
        self.wire = wire
        self.run = run
        self.origin = origin
    }

    /// Every origin publishes its progress: the keyboard shows any run that
    /// holds the microphone. Capturing adds nothing to `recording`.
    func progressed(to phase: RecordingRunPhase) {
        switch phase {
        case .arming: wire.show(.recording, of: run)
        case .capturing: return
        case .finalizing: wire.show(.transcribing, of: run)
        }
    }

    /// Each terminal state gets its own wire value, so the keyboard renders what
    /// the run decided instead of guessing (ADR-0004). A run from another
    /// origin shows its outcome there, so the keyboard only goes back to idle.
    func complete(_ terminalState: RecordingRunTerminalState) async {
        let phase: KeyboardWirePhase = origin.deliversToKeyboard ? .ended(KeyboardWireOutcome(terminalState)) : .idle
        Logger.recording.info(
            "Keyboard completion: \(terminalState.logName) → \(phase.logName) (origin=\(String(describing: self.origin)))"
        )
        wire.show(phase, of: run)
    }
}

private extension KeyboardWireOutcome {
    init(_ terminalState: RecordingRunTerminalState) {
        switch terminalState {
        case .success(let success): self = .text(success.finalText)
        case .emptyResult: self = .emptyResult
        case .cancellation: self = .cancelled
        case .processingFailure(let failure): self = .failed(reason: failure.message)
        }
    }
}

private extension KeyboardWirePhase {
    /// The Bundled Result by length: the run already logged the text.
    var logName: String {
        switch self {
        case .ended(.text(let text)): "bundledResult (\(text.count) chars)"
        case .ended(.failed(let reason)): "failed — \(reason)"
        default: String(describing: self)
        }
    }
}
