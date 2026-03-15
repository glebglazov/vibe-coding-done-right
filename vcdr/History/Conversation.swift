import Foundation

struct Conversation: Identifiable, Equatable {
    let id: UUID
    var turns: [Turn]
    let modeID: UUID
    let modeName: String  // Snapshot for display even if mode is later deleted
    var lastUpdated: Date
    /// Whether external processing (e.g. a bash script) produced the output.
    /// Determines if this entry is rendered and treated as a conversation.
    var hadExternalProcessing: Bool

    struct Turn: Identifiable, Equatable {
        let id: UUID
        let input: String
        let output: String
        let captures: [CapturedContext]
        let timestamp: Date

        // MARK: - Codable (backward-compatible)

        private enum CodingKeys: String, CodingKey {
            case id, input, output, captures, timestamp
            case capturedSelection // Legacy key for backward compat
        }

        init(id: UUID, input: String, output: String, captures: [CapturedContext], timestamp: Date) {
            self.id = id
            self.input = input
            self.output = output
            self.captures = captures
            self.timestamp = timestamp
        }
    }

    /// Preview text for the history list (first turn's input, truncated)
    var previewText: String {
        turns.first?.input ?? ""
    }

    /// Latest output text (last turn's output) for copy actions
    var latestOutput: String {
        turns.last?.output ?? ""
    }

    /// Whether this conversation can be continued — requires external processing
    /// and the original mode still exists with bash script processing.
    func canContinue(modes: [Mode]) -> Bool {
        hadExternalProcessing
            && modes.contains(where: { $0.id == modeID && $0.processingType == .bashScript })
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, turns, modeID, modeName, lastUpdated, hadExternalProcessing
    }
}

extension Conversation.Turn: Codable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(captures, forKey: .captures)
        try container.encode(timestamp, forKey: .timestamp)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        input = try container.decode(String.self, forKey: .input)
        output = try container.decode(String.self, forKey: .output)
        timestamp = try container.decode(Date.self, forKey: .timestamp)

        // Try new format first, fall back to legacy capturedSelection string
        if let decoded = try? container.decode([CapturedContext].self, forKey: .captures) {
            captures = decoded
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .capturedSelection) {
            captures = [CapturedContext(text: legacy, source: .selection)]
        } else {
            captures = []
        }
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
