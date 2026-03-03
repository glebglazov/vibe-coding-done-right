import Foundation

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var turns: [Turn]
    let modeID: UUID
    let modeName: String  // Snapshot for display even if mode is later deleted
    var lastUpdated: Date

    struct Turn: Identifiable, Codable, Equatable {
        let id: UUID
        let input: String
        let output: String
        let capturedSelection: String?
        let timestamp: Date
    }

    /// Preview text for the history list (first turn's input, truncated)
    var previewText: String {
        turns.first?.input ?? ""
    }

    /// Latest output text (last turn's output) for copy actions
    var latestOutput: String {
        turns.last?.output ?? ""
    }
}
