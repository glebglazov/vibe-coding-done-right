import Foundation
import OSLog

struct BashAction: PostTranscriptionAction {
    let name = "Bash Command"
    let commandTemplate: String

    func execute(text: String) async throws {
        let escapedText = text.replacingOccurrences(of: "'", with: "'\\''")
        let command = commandTemplate.replacingOccurrences(of: "{}", with: "'\(escapedText)'")

        Logger.actions.info("Executing bash command")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                Logger.actions.info("Command succeeded")
            } else {
                Logger.actions.error("Command failed with status \(process.terminationStatus): \(output)")
                throw ActionError.executionFailed("Exit code \(process.terminationStatus): \(output)")
            }
        } catch let error as ActionError {
            throw error
        } catch {
            Logger.actions.error("Failed to run command: \(error)")
            throw ActionError.executionFailed(error.localizedDescription)
        }
    }
}
