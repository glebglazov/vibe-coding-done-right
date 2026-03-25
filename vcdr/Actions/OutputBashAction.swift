import Foundation
import OSLog

/// Output action for bash script destinations.
/// The script is responsible for handling its own output — stdout is discarded.
/// No focus restoration is performed; scripts that need the previous app's focus
/// can handle that themselves (e.g., via AppleScript).
struct OutputBashAction: PostTranscriptionAction {
    let name: String
    let commandTemplate: String

    func execute(text: String) async throws -> String? {
        // Run the output script — stdout is intentionally discarded.
        // The script handles its own output (API calls, file writes, etc.)
        try await BashRunner.run(command: commandTemplate, text: text)
        Logger.actions.info("Output bash script executed: \(name)")
        return nil
    }
}
