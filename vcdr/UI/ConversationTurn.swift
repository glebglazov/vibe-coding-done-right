import Foundation

struct ConversationTurn: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let inputSegments: [InputSegment]
    /// Processed result from the mode. Nil when unprocessed (dismissed or non-processing mode).
    let output: String?
    let timestamp: Date

    init(inputSegments: [InputSegment], output: String? = nil) {
        self.id = UUID()
        self.inputSegments = inputSegments
        self.output = output
        self.timestamp = .now
    }

    /// Initializer that preserves an existing ID — used during streaming updates
    /// so SwiftUI updates the view in place instead of recreating it (no flicker).
    init(id: UUID, inputSegments: [InputSegment], output: String? = nil) {
        self.id = id
        self.inputSegments = inputSegments
        self.output = output
        self.timestamp = .now
    }

    // MARK: - Computed

    /// Joined text from all inputSegments (no capture tags).
    var input: String {
        inputSegments.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All captures across inputSegments, preserving order.
    var captures: [CapturedContext] {
        inputSegments.compactMap(\.capture)
    }

    // MARK: - Input Parsing

    enum InputPart: Sendable {
        case text(String)
        case capture(CapturedContext)
    }

    /// Produces display parts from inputSegments — text interleaved with capture blockquotes.
    func parseInput() -> [InputPart] {
        var parts: [InputPart] = []
        for segment in inputSegments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(.text(trimmed))
            }
            if let capture = segment.capture {
                parts.append(.capture(capture))
            }
        }
        return parts
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, output, timestamp
        case inputSegments = "segments"
        // Legacy keys for backward compat
        case input, captures, capturedSelection
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(inputSegments, forKey: .inputSegments)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encode(timestamp, forKey: .timestamp)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? .now

        let rawOutput = try container.decodeIfPresent(String.self, forKey: .output)

        // Try new segment-based format first
        if let decoded = try? container.decode([InputSegment].self, forKey: .inputSegments) {
            inputSegments = decoded
            output = rawOutput
        } else {
            // Legacy format: reconstruct inputSegments from input + captures
            let legacyInput = try container.decodeIfPresent(String.self, forKey: .input) ?? ""

            let legacyCaptures: [CapturedContext]
            if let decoded = try? container.decode([CapturedContext].self, forKey: .captures) {
                legacyCaptures = decoded
            } else if let legacy = try container.decodeIfPresent(String.self, forKey: .capturedSelection) {
                legacyCaptures = [CapturedContext(text: legacy, source: .selection)]
            } else {
                legacyCaptures = []
            }

            inputSegments = Self.migrateToSegments(input: legacyInput, captures: legacyCaptures)
            output = (rawOutput == legacyInput) ? nil : rawOutput
        }
    }

    // MARK: - Legacy Migration

    private static func migrateToSegments(input: String, captures: [CapturedContext]) -> [InputSegment] {
        guard !captures.isEmpty else {
            return [InputSegment(text: input)]
        }

        if input.contains("<capture-1>") {
            return migrateTaggedInput(input: input, captures: captures)
        }

        if captures.count == 1 {
            return [InputSegment(text: input, capture: captures[0])]
        }
        var result = [InputSegment(text: input, capture: captures[0])]
        for capture in captures.dropFirst() {
            result.append(InputSegment(capture: capture))
        }
        return result
    }

    private static func migrateTaggedInput(input: String, captures: [CapturedContext]) -> [InputSegment] {
        var inputSegments: [InputSegment] = []
        var remaining = input
        var captureIndex = 0

        while captureIndex < captures.count {
            let tag = "<capture-\(captureIndex + 1)>"
            let endTag = "</capture-\(captureIndex + 1)>"

            if let tagRange = remaining.range(of: tag) {
                let before = String(remaining[remaining.startIndex..<tagRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                inputSegments.append(InputSegment(text: before, capture: captures[captureIndex]))

                if let endRange = remaining.range(of: endTag) {
                    remaining = String(remaining[endRange.upperBound...])
                } else {
                    remaining = ""
                }
            } else {
                inputSegments.append(InputSegment(capture: captures[captureIndex]))
            }
            captureIndex += 1
        }

        let trailing = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            inputSegments.append(InputSegment(text: trailing))
        }

        return inputSegments
    }
}
