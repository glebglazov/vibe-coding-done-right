import Foundation
import OSLog

enum ToolAvailabilityChecker {
    // MARK: - Constants
    private static let shellPath = "/bin/bash"

    /// Checks which template tools are available by running `which <command>`.
    /// Returns the set of template IDs whose tools are found in PATH.
    /// Templates with no availability command (always available) are included automatically.
    static func checkAll() -> Set<String> {
        var available: Set<String> = []
        for template in ModeTemplate.all {
            if let command = template.availabilityCommand {
                if isToolAvailable(command) {
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
    private static func isToolAvailable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", "zsh -ic 'which \(command)' 2>/dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Logger.settings.warning("Tool check failed for \(command): \(error)")
            return false
        }
    }
}
