import Foundation
import OSLog

extension RecordingRun {
    private static let idlePollInterval: Duration = .milliseconds(20)

    /// DEBUG / test-only: polls until this run reaches its terminal resting
    /// state and returns the recorded outcome. Production code never reads it.
    func waitForIdle(timeout: Duration = .seconds(10)) async -> RecordingRunTerminalState? {
        let start = ContinuousClock.now
        while start.duration(to: .now) < timeout {
            if let terminalState {
                return terminalState
            }
            try? await Task.sleep(for: Self.idlePollInterval)
        }
        return nil
    }

    /// Every terminal branch — mic seizure, model-load throw, finalization
    /// throw, Empty Result, cancellation, success — funnels through `finish`,
    /// so logging here is what makes "which of the four states did this run
    /// reach" answerable from a field report's log (ADR-0004). A Processing
    /// Failure carries the same reason string the user is shown, at error
    /// level; the other states are ordinary lifecycle facts at info.
    func logTerminal(_ terminal: RecordingRunTerminalState) {
        switch terminal {
        case .processingFailure(let failure):
            Logger.recording.error("Run terminal state: \(terminal.logName) — \(failure.message)")
        case .success(let success):
            Logger.recording.info(
                "Run terminal state: \(terminal.logName) (\(success.finalText.count) chars)"
            )
        case .emptyResult, .cancellation:
            Logger.recording.info("Run terminal state: \(terminal.logName)")
        }
    }
}
