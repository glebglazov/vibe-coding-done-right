import Foundation

struct Conversation: Identifiable, Equatable {
    let id: UUID
    var turns: [Turn]
    let modeID: UUID
    let modeName: String  // Snapshot for display even if mode is later deleted
    var lastUpdated: Date
    /// Whether external processing (e.g. a bash script) produced the output.
    /// Determines if this entry is rendered and treated as a conversation.
    let hadExternalProcessing: Bool

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

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, turns, modeID, modeName, lastUpdated, hadExternalProcessing
    }
}

extension Conversation: Codable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(turns, forKey: .turns)
        try container.encode(modeID, forKey: .modeID)
        try container.encode(modeName, forKey: .modeName)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(hadExternalProcessing, forKey: .hadExternalProcessing)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        turns = try container.decode([Turn].self, forKey: .turns)
        modeID = try container.decode(UUID.self, forKey: .modeID)
        modeName = try container.decode(String.self, forKey: .modeName)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        // Default to true for backward compatibility: old multi-turn conversations
        // definitely had processing, and canContinue also checks mode.processingType
        // so old dictation entries won't incorrectly become "continuable."
        hadExternalProcessing = try container.decodeIfPresent(Bool.self, forKey: .hadExternalProcessing) ?? true
    }
}
