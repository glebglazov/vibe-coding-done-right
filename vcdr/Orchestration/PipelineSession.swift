import AppKit

/// Result emitted by RecordingCoordinator after transcription completes.
/// Contains only recording-phase data — no conversation state (CC owns that).
struct RecordingResult {
    let text: String
    let captures: [CapturedContext]
    let previousActiveApp: NSRunningApplication?
    /// Destination override from a hotkey pressed during recording. Nil if none.
    let destinationOverrideID: UUID?
    /// Whether a destination hotkey was pressed during recording.
    let hadDestinationOverride: Bool
    /// Whether the capture panel was visible when recording started.
    let isFollowUp: Bool
}

/// Bundles all per-pipeline-run state. Cleared to nil after each run completes,
/// errors out, or is cancelled — replacing individual property resets.
struct PipelineSession {
    var previousActiveApp: NSRunningApplication?
    var captures: [CapturedContext] = []
    var followUpContext: String?
    var conversationTurns: [ConversationTurn] = []
    var conversationID: UUID?
}
