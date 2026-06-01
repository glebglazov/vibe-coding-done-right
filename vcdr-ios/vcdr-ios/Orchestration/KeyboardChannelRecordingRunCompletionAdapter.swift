import Foundation

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
                keyboardChannel.publishBundledResult(success.finalText)
            } else {
                keyboardChannel.publish(.idle)
            }
        case .emptyResult:
            keyboardChannel.publish(deliversToKeyboard ? .emptyResult : .idle)
        case .cancellation, .processingFailure:
            keyboardChannel.publish(.idle)
        }
    }
}
