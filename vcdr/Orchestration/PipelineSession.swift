import AppKit

/// Bundles all per-pipeline-run state. Cleared to nil after each run completes,
/// errors out, or is cancelled — replacing individual property resets.
struct PipelineSession {
    var previousActiveApp: NSRunningApplication?
    var capturedSelection: String?
    var outputDestinationOverride: UUID?
    var followUpContext: String?
    var conversationTurns: [ConversationTurn] = []
    var conversationID: UUID?
    var isFollowUpFromVisibleOutputPanel: Bool = false
}
