import Foundation
import OSLog

enum OutputActionFactory {
    /// Creates the appropriate PostTranscriptionAction for a given output destination.
    /// Returns nil for `.outputPanel` destinations (handled separately by callers).
    static func makeAction(
        for destination: OutputDestination,
        targetAppPID: pid_t?,
        conversationID: UUID,
        saveResultToClipboard: Bool
    ) -> (any PostTranscriptionAction)? {
        switch destination.type {
        case .paste:
            return PasteAction(targetAppPID: targetAppPID, saveResultToClipboard: saveResultToClipboard)
        case .bashScript:
            return OutputBashAction(
                name: destination.name,
                commandTemplate: destination.bashCommand,
                conversationID: conversationID.uuidString
            )
        case .outputPanel:
            return nil
        case .copy:
            return CopyAction()
        }
    }
}
