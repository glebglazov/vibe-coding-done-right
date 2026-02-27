import Foundation
import AppKit
import OSLog

struct BashAction: PostTranscriptionAction {
    let name = "Bash Command"
    let commandTemplate: String

    /// PID of the app to restore focus to when pasting output.
    /// Using pid_t instead of NSRunningApplication to keep the action Sendable.
    private let targetAppPID: pid_t?

    init(commandTemplate: String, targetAppPID: pid_t? = nil) {
        self.commandTemplate = commandTemplate
        self.targetAppPID = targetAppPID
    }

    func execute(text: String) async throws -> String? {
        let output = try await runProcess(command: commandTemplate, text: text)

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            Logger.actions.info("Script output copied to clipboard")
        }

        return output
    }

    // MARK: - Process Execution

    private func runProcess(command: String, text: String) async throws -> String {
        // Replace {} with $VCDR_TEXT shell variable reference.
        // The text is passed via environment variable to avoid quoting/escaping issues.
        let resolvedCommand = command.replacingOccurrences(of: "{}", with: "$VCDR_TEXT")

        Logger.actions.info("Executing bash command")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", resolvedCommand]

        // Pass transcribed text as environment variable — safe regardless of quoting
        var env = ProcessInfo.processInfo.environment
        env["VCDR_TEXT"] = text
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let terminationStatus: Int32
        do {
            terminationStatus = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            Logger.actions.error("Failed to run command: \(error)")
            throw ActionError.executionFailed(error.localizedDescription)
        }

        // Process has exited — readDataToEndOfFile is non-blocking at this point
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if terminationStatus == 0 {
            Logger.actions.info("Command succeeded")
            return output
        } else {
            Logger.actions.error("Command failed with status \(terminationStatus): \(output)")
            throw ActionError.executionFailed("Exit code \(terminationStatus): \(output)")
        }
    }
}
