import Foundation

struct Conversation: Identifiable, Equatable, Codable {
    let id: UUID
    var inputSegments: [InputSegment]
    var output: String?
    let modeID: UUID
    let modeName: String  // Snapshot for display even if mode is later deleted
    var lastUpdated: Date

    /// Whether processed output is present.
    var hadExternalProcessing: Bool {
        output != nil
    }

    /// Raw input text joined from all segments.
    var inputText: String {
        inputSegments.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Preview text for the history list — prefers processed output when available.
    var previewText: String {
        output ?? inputText
    }

    /// Output text for copy actions, falling back to input text.
    var copyableText: String {
        output ?? inputText
    }

    // MARK: - Codable (backward-compatible with multi-turn format)

    private enum CodingKeys: String, CodingKey {
        case id, modeID, modeName, lastUpdated
        // New flat format
        case inputSegments = "segments"
        case output
        // Legacy multi-turn format
        case turns
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(inputSegments, forKey: .inputSegments)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encode(modeID, forKey: .modeID)
        try container.encode(modeName, forKey: .modeName)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }

    init(id: UUID, inputSegments: [InputSegment], output: String?, modeID: UUID, modeName: String, lastUpdated: Date) {
        self.id = id
        self.inputSegments = inputSegments
        self.output = output
        self.modeID = modeID
        self.modeName = modeName
        self.lastUpdated = lastUpdated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        modeID = try container.decode(UUID.self, forKey: .modeID)
        modeName = try container.decode(String.self, forKey: .modeName)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)

        // Try new flat format first
        if let segments = try? container.decode([InputSegment].self, forKey: .inputSegments) {
            inputSegments = segments
            output = try container.decodeIfPresent(String.self, forKey: .output)
        } else if let turns = try? container.decode([LegacyConversationTurn].self, forKey: .turns) {
            // Legacy multi-turn format — take the last meaningful turn
            let meaningful = turns.last(where: { $0.output != nil }) ?? turns.last
            inputSegments = meaningful?.inputSegments ?? [InputSegment()]
            output = meaningful?.output
        } else {
            inputSegments = [InputSegment()]
            output = nil
        }
    }
}

// MARK: - Legacy Turn for Migration

/// Minimal decodable struct for migrating old multi-turn history data.
private struct LegacyConversationTurn: Decodable {
    let inputSegments: [InputSegment]
    let output: String?

    private enum CodingKeys: String, CodingKey {
        case inputSegments = "segments"
        case output
        case input, captures, capturedSelection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawOutput = try container.decodeIfPresent(String.self, forKey: .output)

        if let decoded = try? container.decode([InputSegment].self, forKey: .inputSegments) {
            inputSegments = decoded
            output = rawOutput
        } else {
            // Legacy format: reconstruct from input + captures
            let legacyInput = try container.decodeIfPresent(String.self, forKey: .input) ?? ""
            let legacyCaptures: [CapturedContext]
            if let decoded = try? container.decode([CapturedContext].self, forKey: .captures) {
                legacyCaptures = decoded
            } else if let legacy = try container.decodeIfPresent(String.self, forKey: .capturedSelection) {
                legacyCaptures = [CapturedContext(text: legacy, source: .selection)]
            } else {
                legacyCaptures = []
            }

            if legacyCaptures.isEmpty {
                inputSegments = [InputSegment(text: legacyInput)]
            } else if legacyCaptures.count == 1 {
                inputSegments = [InputSegment(text: legacyInput, capture: legacyCaptures[0])]
            } else {
                var segs = [InputSegment(text: legacyInput, capture: legacyCaptures[0])]
                for capture in legacyCaptures.dropFirst() {
                    segs.append(InputSegment(capture: capture))
                }
                inputSegments = segs
            }
            output = (rawOutput == legacyInput) ? nil : rawOutput
        }
    }
}
