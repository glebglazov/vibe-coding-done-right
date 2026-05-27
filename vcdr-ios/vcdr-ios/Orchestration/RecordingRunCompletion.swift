import Foundation

struct RecordingRunSuccess: Equatable {
    let conversationID: UUID
    let transcript: String
    let processed: String?
    let finalText: String
    let captures: [String]
    let historyLabel: String?
}

struct RecordingRunFailure: Equatable {
    let message: String
}

enum RecordingRunTerminalState: Equatable {
    case success(RecordingRunSuccess)
    case emptyResult
    case cancellation
    case processingFailure(RecordingRunFailure)
}

@MainActor
protocol RecordingRunCompletionAdapter: AnyObject {
    func complete(_ terminalState: RecordingRunTerminalState) async
}
