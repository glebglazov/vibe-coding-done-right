import AppKit

/// Bundles all per-pipeline-run state. Cleared to nil after each run completes,
/// errors out, or is cancelled — replacing individual property resets.
struct PipelineSession {
    var previousActiveApp: NSRunningApplication?
    var captures: [CapturedContext] = []
    /// When capture runs concurrently (e.g. Cmd+C fallback polling), this task
    /// holds the in-flight result. Resolved into `captures` before use.
    var captureTask: Task<CapturedContext?, Never>?
    var followUpContext: String?
    var conversationTurns: [ConversationTurn] = []
    var conversationID: UUID?
    var isFollowUpFromVisibleCapturePanel: Bool = false
}

/// Data needed by RecordingCoordinator to start a follow-up recording
/// from an active CaptureCoordinator session. Contains only the fields
/// relevant for continuing a conversation — no transient pipeline state.
struct FollowUpSnapshot {
    let conversationID: UUID?
    let conversationTurns: [ConversationTurn]
    let followUpContext: String?
    let captures: [CapturedContext]
    let previousActiveApp: NSRunningApplication?
}

extension PipelineSession {
    /// Creates a session initialized with follow-up context from a snapshot.
    /// Sets `isFollowUpFromVisibleCapturePanel = true` automatically.
    init(followUp snapshot: FollowUpSnapshot) {
        self.init()
        self.conversationID = snapshot.conversationID
        self.conversationTurns = snapshot.conversationTurns
        self.followUpContext = snapshot.followUpContext
        self.captures = snapshot.captures
        self.previousActiveApp = snapshot.previousActiveApp
        self.isFollowUpFromVisibleCapturePanel = true
    }
}
