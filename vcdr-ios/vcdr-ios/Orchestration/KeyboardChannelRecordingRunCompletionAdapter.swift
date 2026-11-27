import Foundation
import OSLog

/// Every wire value a Recording Run publishes comes from here: its progress
/// and its terminal state.
@MainActor
final class KeyboardChannelRecordingRunCompletionAdapter: RecordingRunCompletionAdapter {
    private let keyboardChannel: any KeyboardChannelProtocol
    private let origin: RecordingRunOrigin

    init(keyboardChannel: any KeyboardChannelProtocol, origin: RecordingRunOrigin) {
        self.keyboardChannel = keyboardChannel
        self.origin = origin
    }

    /// Every origin publishes its progress: the keyboard shows any run that
    /// holds the microphone. Capturing adds nothing to `recording`.
    func progressed(to phase: RecordingRunPhase) {
        let wireState: KeyboardChannel.RecordingState
        switch phase {
        case .arming: wireState = .recording
        case .capturing: return
        case .finalizing: wireState = .transcribing
        }
        Logger.recording.info("Wire state written: \(wireState.rawValue)")
        keyboardChannel.publish(wireState)
    }

    /// Each terminal state gets its own wire value, so the keyboard renders what
    /// the run decided instead of guessing from `.idle` (ADR-0004).
    ///
    func complete(_ terminalState: RecordingRunTerminalState) async {
        guard origin.deliversToKeyboard else {
            log(terminalState, publishes: KeyboardChannel.RecordingState.idle.rawValue)
            keyboardChannel.publish(.idle)
            return
        }

        switch terminalState {
        case .success(let success):
            log(terminalState, publishes: "bundledResult (\(success.finalText.count) chars)")
            keyboardChannel.publishBundledResult(success.finalText)
        case .emptyResult:
            log(terminalState, publishes: KeyboardChannel.RecordingState.emptyResult.rawValue)
            keyboardChannel.publish(.emptyResult)
        case .cancellation:
            log(terminalState, publishes: KeyboardChannel.RecordingState.cancelled.rawValue)
            keyboardChannel.publish(.cancelled)
        case .processingFailure(let failure):
            log(terminalState, publishes: "\(KeyboardChannel.RecordingState.failed.rawValue) — \(failure.message)")
            keyboardChannel.publishFailure(reason: failure.message)
        }
    }

    private func log(_ terminalState: RecordingRunTerminalState, publishes wireState: String) {
        Logger.recording.info(
            "Keyboard completion: \(terminalState.logName) → \(wireState)"
                + " (origin=\(String(describing: origin)))"
        )
    }
}
