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

    /// Log-facing name of the terminal state. The run's own terminal line and
    /// the completion adapters' published-state lines spell it the same way, so
    /// a reader can pair "what the run decided" with "what the keyboard was
    /// told" from the log alone (ADR-0004).
    var logName: String {
        switch self {
        case .success: "success"
        case .emptyResult: "empty result"
        case .cancellation: "cancellation"
        case .processingFailure: "processing failure"
        }
    }
}

@MainActor
protocol RecordingRunCompletionAdapter: AnyObject {
    func complete(_ terminalState: RecordingRunTerminalState) async
}
