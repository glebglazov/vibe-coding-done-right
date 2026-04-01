import Foundation
import OSLog

enum ToolAvailabilityChecker {
    // MARK: - Constants
    private static let shellPath = "/bin/bash"

    /// Checks which template tools are available by running `which <command>`.
    /// Returns the set of template IDs whose tools are found in PATH.
    /// Templates with no availability command (always available) are included automatically.
    static func checkAll() async -> Set<String> {
        var available: Set<String> = []
        for template in ModeTemplate.all {
            if let command = template.availabilityCommand {
                if await isToolAvailable(command) {
                    available.insert(template.id)
                }
            } else {
                available.insert(template.id)
            }
        }
        Logger.settings.info("Template tool availability: \(available)")
        return available
    }

    /// Runs `which <command>` via the user's interactive zsh to check PATH.
    /// Uses `zsh -ic` to load the user's shell profile so tools installed
    /// via npm, brew, etc. are found.
    /// Runs process.waitUntilExit() off the main thread to avoid blocking.
    private static func isToolAvailable(_ command: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", "zsh -ic 'which \(command)' 2>/dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Logger.settings.warning("Tool check failed for \(command): \(error)")
            return false
        }

        // Wait for process completion off the calling thread
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus == 0)
            }
        }
    }
}
