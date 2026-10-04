import Foundation

/// Boundary between the submission pipeline and the Local Agent CLI the mode
/// names. The agent is an LLM the app does not control, so tests stand in for
/// it here, as they do for cloud providers at `AIProcessingPort`.
protocol LocalAgentPort: Sendable {
    /// Runs the mode's Local Agent on `structuredText`, which already carries the
    /// system prompt at its top, and returns what the agent printed.
    func process(
        structuredText: String,
        mode: Mode,
        environment: [String: String]
    ) async throws -> String
}

struct LocalAgentAdapter: LocalAgentPort {
    func process(
        structuredText: String,
        mode: Mode,
        environment: [String: String]
    ) async throws -> String {
        try await BashRunner.run(
            command: mode.localAgentProvider.command,
            text: structuredText,
            extraEnvironment: environment
        )
    }
}
