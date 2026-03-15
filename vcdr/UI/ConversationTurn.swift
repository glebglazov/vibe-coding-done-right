import Foundation

struct ConversationTurn: Identifiable, Sendable {
    let id: UUID
    let input: String   // Raw user text (transcription or typed)
    let output: String  // Processed result (after bash)
    let captures: [CapturedContext]

    init(input: String, output: String, captures: [CapturedContext] = []) {
        self.id = UUID()
        self.input = input
        self.output = output
        self.captures = captures
    }

    /// Initializer that preserves an existing ID — used during streaming updates
    /// so SwiftUI updates the view in place instead of recreating it (no flicker).
    init(id: UUID, input: String, output: String, captures: [CapturedContext] = []) {
        self.id = id
        self.input = input
        self.output = output
        self.captures = captures
    }

    // MARK: - Input Parsing

    enum InputPart: Sendable {
        case text(String)
        case capture(CapturedContext)
    }

    /// Splits input text on `<capture-N>...</capture-N>` boundaries, pairing each
    /// tag with the corresponding `CapturedContext` from the turn.
    func parseInput() -> [InputPart] {
        guard !captures.isEmpty else {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        }

        var parts: [InputPart] = []
        var remaining = input
        var captureIndex = 0

        while captureIndex < captures.count {
            let tag = "<capture-\(captureIndex + 1)>"
            let endTag = "</capture-\(captureIndex + 1)>"

            if let tagRange = remaining.range(of: tag) {
                let before = String(remaining[remaining.startIndex..<tagRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty {
                    parts.append(.text(before))
                }
                parts.append(.capture(captures[captureIndex]))

                if let endRange = remaining.range(of: endTag) {
                    remaining = String(remaining[endRange.upperBound...])
                } else {
                    remaining = ""
                }
            } else {
                // Tag not found — append capture from the model directly
                parts.append(.capture(captures[captureIndex]))
            }
            captureIndex += 1
        }

        let trailing = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            parts.append(.text(trailing))
        }

        return parts
    }
}
