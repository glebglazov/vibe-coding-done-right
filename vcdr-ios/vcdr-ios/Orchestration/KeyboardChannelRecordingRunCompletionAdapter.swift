import Foundation
import OSLog

@MainActor
final class KeyboardChannelRecordingRunCompletionAdapter: RecordingRunCompletionAdapter {
    private let keyboardChannel: any KeyboardChannelProtocol
    private let deliversToKeyboard: Bool

    init(keyboardChannel: any KeyboardChannelProtocol, deliversToKeyboard: Bool) {
        self.keyboardChannel = keyboardChannel
        self.deliversToKeyboard = deliversToKeyboard
    }

    func complete(_ terminalState: RecordingRunTerminalState) async {
        switch terminalState {
        case .success(let success):
            if deliversToKeyboard {
                log(terminalState, publishes: "bundledResult (\(success.finalText.count) chars)")
                keyboardChannel.publishBundledResult(success.finalText)
            } else {
                log(terminalState, publishes: KeyboardChannel.RecordingState.idle.rawValue)
                keyboardChannel.publish(.idle)
            }
        case .emptyResult:
            let wireState: KeyboardChannel.RecordingState = deliversToKeyboard ? .emptyResult : .idle
            log(terminalState, publishes: wireState.rawValue)
            keyboardChannel.publish(wireState)
        case .cancellation, .processingFailure:
            log(terminalState, publishes: KeyboardChannel.RecordingState.idle.rawValue)
            keyboardChannel.publish(.idle)
        }
    }

    /// This adapter is where the four terminal states collapse onto a narrower
    /// set of wire values (ADR-0004), so which value a given state produced —
    /// and whether `deliversToKeyboard` steered it — is only recoverable from a
    /// log if the decision is recorded as it is made.
    private func log(_ terminalState: RecordingRunTerminalState, publishes wireState: String) {
        Logger.recording.info(
            "Keyboard completion: \(terminalState.logName) → \(wireState)"
                + " (deliversToKeyboard=\(deliversToKeyboard))"
        )
    }
}
