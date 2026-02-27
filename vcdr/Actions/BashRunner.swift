import Foundation
import OSLog

/// Shared utility for running bash commands with text input via $VCDR_TEXT.
/// Used by both the processing pipeline (mode's bash script) and output
/// destinations (bash script destinations).
enum BashRunner {

    // MARK: - Constants

    private static let textPlaceholder = "{}"
    private static let textEnvironmentVariable = "VCDR_TEXT"
    private static let shellPath = "/bin/bash"

    /// Runs a bash command with the given text passed as $VCDR_TEXT environment variable.
    /// The `{}` placeholder in the command is replaced with `$VCDR_TEXT`.
    /// Returns the command's stdout as a String.
    @discardableResult
    static func run(command: String, text: String) async throws -> String {
        let resolvedCommand = command.replacingOccurrences(of: textPlaceholder, with: "$\(textEnvironmentVariable)")

        Logger.actions.info("Executing bash command")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", resolvedCommand]

        var env = ProcessInfo.processInfo.environment
        env[textEnvironmentVariable] = text
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
