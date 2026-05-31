import Foundation

@MainActor
final class HistoryRecordingRunCompletionAdapter: RecordingRunCompletionAdapter {
    private var history: (any HistoryStore)?
    private var pendingSuccesses: [RecordingRunSuccess] = []

    init(history: (any HistoryStore)? = nil) {
        self.history = history
    }

    func complete(_ terminalState: RecordingRunTerminalState) async {
        guard case .success(let success) = terminalState else { return }

        guard let history else {
            pendingSuccesses.append(success)
            return
        }
        record(success, in: history)
    }

    func setHistory(_ history: any HistoryStore) {
        guard self.history == nil else { return }
        self.history = history
        for success in pendingSuccesses {
            record(success, in: history)
        }
        pendingSuccesses.removeAll()
    }

    private func record(_ success: RecordingRunSuccess, in history: any HistoryStore) {
        let primarySegment = InputSegment(text: success.transcript)
        let captureSegments = success.captures
            .filter { !$0.isEmpty }
            .map { InputSegment(capture: CapturedContext(text: $0, source: .selection)) }

        history.record(
            conversationID: success.conversationID,
            inputSegments: [primarySegment] + captureSegments,
            output: success.processed != nil ? success.finalText : nil,
            label: success.historyLabel
        )
    }
}
