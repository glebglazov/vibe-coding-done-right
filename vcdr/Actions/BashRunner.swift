import Foundation
import OSLog

/// Shared utility for running bash commands with text input via $VCDR_TEXT.
/// Used by both the processing pipeline (mode's bash script) and output
/// destinations (bash script destinations).
enum BashRunner {

    // MARK: - Constants

    private static let textPlaceholder = "{}"
    private static let textEnvironmentVariable = "VCDR_TEXT"
    private static let dictationEnvironmentVariable = "VCDR_DICTATION"
    private static let conversationEnvironmentVariable = "VCDR_CONVERSATION"
    private static let conversationIDEnvironmentVariable = "VCDR_CONV_ID"
    private static let shellPath = "/bin/bash"

    /// Runs a bash command with the given text passed as $VCDR_TEXT environment variable.
    /// The `{}` placeholder in the command is replaced with `$VCDR_TEXT`.
    ///
    /// Optional environment variables:
    /// - `$VCDR_DICTATION`: Alias for `$VCDR_TEXT` (preferred going forward)
    /// - `$VCDR_CONVERSATION`: JSON array of messages in OpenAI chat format
    ///   (`[{"role":"system","content":"..."},{"role":"user","content":"..."},...]`)
    /// - `$VCDR_CONV_ID`: Conversation UUID for stateful scripts
    ///
    /// Returns the command's stdout as a String.
    @discardableResult
    static func run(
        command: String,
        text: String,
        conversationMessages: String? = nil,
        conversationID: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) async throws -> String {
        let resolvedCommand = command.replacingOccurrences(of: textPlaceholder, with: "$\(textEnvironmentVariable)")

        if !extraEnvironment.isEmpty {
            Logger.actions.info("Executing bash command with extra env: \(extraEnvironment)")
        } else {
            Logger.actions.info("Executing bash command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", resolvedCommand]

        var env = ProcessInfo.processInfo.environment
        env[textEnvironmentVariable] = text
        env[dictationEnvironmentVariable] = text
        if let conversationMessages {
            env[conversationEnvironmentVariable] = conversationMessages
        }
        if let conversationID {
            env[conversationIDEnvironmentVariable] = conversationID
        }
        for (key, value) in extraEnvironment {
            env[key] = value
        }
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

    /// Streaming variant of `run()`. Returns an `AsyncThrowingStream` that yields
    /// stdout chunks as they arrive, plus a cancel closure that terminates the process.
    static func runStreaming(
        command: String,
        text: String,
        conversationMessages: String? = nil,
        conversationID: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) -> (stream: AsyncThrowingStream<String, Error>, cancel: @Sendable () -> Void) {
        let resolvedCommand = command.replacingOccurrences(of: textPlaceholder, with: "$\(textEnvironmentVariable)")

        Logger.actions.info("Executing streaming bash command")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", resolvedCommand]

        var env = ProcessInfo.processInfo.environment
        env[textEnvironmentVariable] = text
        env[dictationEnvironmentVariable] = text
        if let conversationMessages {
            env[conversationEnvironmentVariable] = conversationMessages
        }
        if let conversationID {
            env[conversationIDEnvironmentVariable] = conversationID
        }
        for (key, value) in extraEnvironment {
            env[key] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // nonisolated(unsafe) is safe here: the process and pipes are used exclusively
        // inside the detached Task and the continuation callbacks, with no concurrent access.
        nonisolated(unsafe) let unsafeProcess = process
        nonisolated(unsafe) let unsafeStdoutPipe = stdoutPipe
        nonisolated(unsafe) let unsafeStderrPipe = stderrPipe

        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.onTermination = { @Sendable _ in
                if unsafeProcess.isRunning {
                    unsafeProcess.terminate()
                }
            }

            do {
                try unsafeProcess.run()
            } catch {
                Logger.actions.error("Failed to run streaming command: \(error)")
                continuation.finish(throwing: ActionError.executionFailed(error.localizedDescription))
                return
            }

            // Read stdout in a detached task — availableData blocks until data arrives or EOF
            Task.detached {
                let handle = unsafeStdoutPipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break } // EOF
                    if let chunk = String(data: data, encoding: .utf8) {
                        continuation.yield(chunk)
                    }
                }

                // Wait for process to finish (it should already be done after stdout EOF)
                unsafeProcess.waitUntilExit()
                let status = unsafeProcess.terminationStatus

                if status == 0 {
                    Logger.actions.info("Streaming command succeeded")
                    continuation.finish()
                } else {
                    let stderrData = unsafeStderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                    Logger.actions.error("Streaming command failed with status \(status): \(stderrText)")
                    continuation.finish(throwing: ActionError.executionFailed("Exit code \(status): \(stderrText)"))
                }
            }
        }

        let cancel: @Sendable () -> Void = {
            if unsafeProcess.isRunning {
                unsafeProcess.terminate()
            }
        }

        return (stream: stream, cancel: cancel)
    }
}
