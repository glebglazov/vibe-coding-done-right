import Foundation

/// Lightweight display model for a single input + optional output.
/// Used by the capture panel and turn view for rendering — not persisted.
struct DisplayedTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let inputSegments: [InputSegment]
    let output: String?

    init(inputSegments: [InputSegment], output: String? = nil) {
        self.id = UUID()
        self.inputSegments = inputSegments
        self.output = output
    }

    /// Initializer that preserves an existing ID — used during streaming updates
    /// so SwiftUI updates the view in place instead of recreating it (no flicker).
    init(id: UUID, inputSegments: [InputSegment], output: String? = nil) {
        self.id = id
        self.inputSegments = inputSegments
        self.output = output
    }

    /// Joined text from all inputSegments.
    var input: String {
        inputSegments.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All captures across inputSegments, preserving order.
    var captures: [CapturedContext] {
        inputSegments.compactMap(\.capture)
    }

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
}
