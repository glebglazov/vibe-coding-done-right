import AppKit

/// Bundles all per-pipeline-run state. Cleared to nil after each run completes,
/// errors out, or is cancelled — replacing individual property resets.
struct PipelineSession {
    var previousActiveApp: NSRunningApplication?
    var capturedSelection: String?
    /// When capture runs concurrently (e.g. Cmd+C fallback polling), this task
    /// holds the in-flight result. Resolved into `capturedSelection` before use.
    var capturedSelectionTask: Task<String?, Never>?
    var outputDestinationOverride: UUID?
    var followUpContext: String?
    var conversationTurns: [ConversationTurn] = []
    var conversationID: UUID?
    var isFollowUpFromVisibleOutputPanel: Bool = false
}
