import Foundation
import OSLog

enum OutputActionFactory {
    /// Creates the appropriate PostTranscriptionAction for a given output destination.
    static func makeAction(
        for destination: OutputDestination,
        targetAppPID: pid_t?,
        saveResultToClipboard: Bool
    ) -> (any PostTranscriptionAction)? {
        switch destination.type {
        case .paste:
            return PasteAction(targetAppPID: nil, saveResultToClipboard: saveResultToClipboard)
        case .pasteToInitialApp:
            return PasteAction(targetAppPID: targetAppPID, saveResultToClipboard: saveResultToClipboard)
        case .bashScript:
            return OutputBashAction(
                name: destination.name,
                commandTemplate: destination.bashCommand
            )
        case .copy:
            return CopyAction()
        }
    }
}
