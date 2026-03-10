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
}
