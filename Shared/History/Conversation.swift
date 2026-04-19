import Foundation

struct Conversation: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var inputSegments: [InputSegment]
    var output: String?
    var label: String?
    var lastUpdated: Date
    var schemaVersion: Int
    /// Top-level JSON keys written by a newer schema that this binary doesn't
    /// know about. Preserved verbatim so old readers round-trip new data without
    /// clobbering unknown fields.
    var extras: [String: AnyJSON]

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

    init(
        id: UUID,
        inputSegments: [InputSegment],
        output: String?,
        label: String?,
        lastUpdated: Date,
        schemaVersion: Int = Conversation.currentSchemaVersion,
        extras: [String: AnyJSON] = [:]
    ) {
        self.id = id
        self.inputSegments = inputSegments
        self.output = output
        self.label = label
        self.lastUpdated = lastUpdated
        self.schemaVersion = schemaVersion
        self.extras = extras
    }

    static let currentSchemaVersion = 1

    // MARK: - Codable

    /// Known top-level keys this binary recognizes. Anything else lands in `extras`.
    private static let knownKeys: Set<String> = [
        "id", "segments", "output", "label", "lastUpdated", "schemaVersion",
        // Legacy / backward-compat keys:
        "modeID", "modeName", "turns",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)

        let id = try container.decode(UUID.self, forKey: AnyCodingKey("id"))
        let lastUpdated = try container.decode(Date.self, forKey: AnyCodingKey("lastUpdated"))
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("schemaVersion"))
            ?? Conversation.currentSchemaVersion

        // Prefer the new `label` field; fall back to legacy `modeName`.
        let label: String?
        if let newLabel = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("label")) {
            label = newLabel
        } else if let legacyModeName = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("modeName")) {
            label = legacyModeName.isEmpty ? nil : legacyModeName
        } else {
            label = nil
        }

        // Decode input segments from the new flat format or legacy multi-turn.
        let inputSegments: [InputSegment]
        let output: String?
        if let segments = try container.decodeIfPresent([InputSegment].self, forKey: AnyCodingKey("segments")) {
            inputSegments = segments
            output = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("output"))
        } else if let turns = try container.decodeIfPresent([LegacyConversationTurn].self, forKey: AnyCodingKey("turns")) {
            let meaningful = turns.last(where: { $0.output != nil }) ?? turns.last
            inputSegments = meaningful?.inputSegments ?? [InputSegment()]
            output = meaningful?.output
        } else {
            inputSegments = [InputSegment()]
            output = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("output"))
        }

        // Capture any unknown top-level keys into extras so future-schema
        // fields round-trip through older readers unchanged.
        var extras: [String: AnyJSON] = [:]
        for key in container.allKeys where !Conversation.knownKeys.contains(key.stringValue) {
            if let value = try? container.decode(AnyJSON.self, forKey: key) {
                extras[key.stringValue] = value
            }
        }

        self.init(
            id: id,
            inputSegments: inputSegments,
            output: output,
            label: label,
            lastUpdated: lastUpdated,
            schemaVersion: schemaVersion,
            extras: extras
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(inputSegments, forKey: AnyCodingKey("segments"))
        try container.encodeIfPresent(output, forKey: AnyCodingKey("output"))
        try container.encodeIfPresent(label, forKey: AnyCodingKey("label"))
        try container.encode(lastUpdated, forKey: AnyCodingKey("lastUpdated"))
        try container.encode(schemaVersion, forKey: AnyCodingKey("schemaVersion"))

        // Re-emit preserved unknown fields verbatim. If a caller explicitly
        // stored a value under a known key, the known-key write above wins.
        for (key, value) in extras where !Conversation.knownKeys.contains(key) {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

// MARK: - Dynamic CodingKey

private struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
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
