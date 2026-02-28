import Foundation

struct ConversationTurn: Identifiable, Sendable {
    let id = UUID()
    let input: String   // Raw user text (transcription or typed)
    let output: String  // Processed result (after bash)
}
