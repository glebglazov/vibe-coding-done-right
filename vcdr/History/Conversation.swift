import Foundation

struct Conversation: Identifiable, Equatable, Codable {
    let id: UUID
    var turns: [ConversationTurn]
    let modeID: UUID
    let modeName: String  // Snapshot for display even if mode is later deleted
    var lastUpdated: Date

    /// Whether any turn has mode output — derived from turns, not stored.
    var hadExternalProcessing: Bool {
        turns.contains { $0.output != nil }
    }

    init(id: UUID, turns: [ConversationTurn], modeID: UUID, modeName: String, lastUpdated: Date) {
        self.id = id
        self.turns = turns
        self.modeID = modeID
        self.modeName = modeName
        self.lastUpdated = lastUpdated
    }

    /// Preview text for the history list (first turn's input, truncated)
    var previewText: String {
        turns.first?.input ?? ""
    }

    /// Latest processed output for follow-up context and copy actions.
    var latestOutput: String? {
        turns.last(where: { $0.output != nil })?.output
    }

    /// Whether this conversation can be continued — requires external processing
    /// and the original mode still exists with bash script processing.
    func canContinue(modes: [Mode]) -> Bool {
        hadExternalProcessing
            && modes.contains(where: { $0.id == modeID && $0.processingType == .bashScript })
    }
}
