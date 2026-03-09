import Foundation

struct ConversationTurn: Identifiable, Sendable {
    let id: UUID
    let input: String   // Raw user text (transcription or typed)
    let output: String  // Processed result (after bash)
    let capturedSelection: String?  // Text highlighted in the frontmost app when recording started

    init(input: String, output: String, capturedSelection: String? = nil) {
        self.id = UUID()
        self.input = input
        self.output = output
        self.capturedSelection = capturedSelection
    }

    /// Initializer that preserves an existing ID — used during streaming updates
    /// so SwiftUI updates the view in place instead of recreating it (no flicker).
    init(id: UUID, input: String, output: String, capturedSelection: String? = nil) {
        self.id = id
        self.input = input
        self.output = output
        self.capturedSelection = capturedSelection
    }
}
