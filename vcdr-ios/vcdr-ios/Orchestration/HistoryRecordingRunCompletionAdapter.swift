import Foundation

@MainActor
final class HistoryRecordingRunCompletionAdapter: RecordingRunCompletionAdapter {
    private let history: (any HistoryStore)?

    init(history: (any HistoryStore)?) {
        self.history = history
    }

    func complete(_ terminalState: RecordingRunTerminalState) async {
        guard case .success(let success) = terminalState else { return }

        let primarySegment = InputSegment(text: success.transcript)
        let captureSegments = success.captures
            .filter { !$0.isEmpty }
            .map { InputSegment(capture: CapturedContext(text: $0, source: .selection)) }

        history?.record(
            conversationID: success.conversationID,
            inputSegments: [primarySegment] + captureSegments,
            output: success.processed != nil ? success.finalText : nil,
            label: success.historyLabel
        )
    }
}
