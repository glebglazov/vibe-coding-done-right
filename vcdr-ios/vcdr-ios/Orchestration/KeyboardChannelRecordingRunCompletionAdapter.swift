import Foundation
import OSLog

@MainActor
final class KeyboardChannelRecordingRunCompletionAdapter: RecordingRunCompletionAdapter {
    private let keyboardChannel: any KeyboardChannelProtocol
    private let origin: RecordingRunOrigin

    init(keyboardChannel: any KeyboardChannelProtocol, origin: RecordingRunOrigin) {
        self.keyboardChannel = keyboardChannel
        self.origin = origin
    }

    /// Each terminal state gets its own wire value, so the keyboard renders what
    /// the run decided instead of guessing from `.idle` (ADR-0004).
    ///
    /// A run that does not deliver to the keyboard still publishes `.idle`, and
    /// that is the only remaining publisher of it: the run was driven from the
    /// app surface or a Shortcut, which show the outcome themselves, so the
    /// keyboard has genuinely nothing to render — and the channel must still come off the
    /// `.recording`/`.transcribing` it was left on.
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

    /// This adapter is the only place a terminal state becomes a wire value
    /// (ADR-0004), so which value a given state produced — and whether the
    /// run's origin steered it to plain idle — is only recoverable from
    /// a log if the decision is recorded as it is made.
    private func log(_ terminalState: RecordingRunTerminalState, publishes wireState: String) {
        Logger.recording.info(
            "Keyboard completion: \(terminalState.logName) → \(wireState)"
                + " (origin=\(String(describing: origin)))"
        )
    }
}
