import Foundation
@testable import vcdr_mac

/// Test double for `AIProcessingPort`. Pops one result per `process(...)` call
/// from a scripted list, recording the arguments of each call so tests can
/// assert exact parity between the initial attempt and any retry.
///
/// If a test configures `.failure(...)` then `.success(...)`, asserting that
/// the `structuredText` received on both calls is identical mechanically
/// proves that the initial attempt and the retry share one code path.
///
/// Main-actor isolated, as the app module's default isolation makes
/// `AIProcessingPort`; that isolation is also what makes it `Sendable`.
@MainActor
final class ScriptedAIProcessing: AIProcessingPort {

    struct ReceivedCall: Equatable, Sendable {
        let structuredText: String
        let modeID: UUID
        let spellingHints: SpellingHints
        let apiKey: String
        let parameterValues: [String: String]
    }

    private var pending: [Result<String, Error>]
    private(set) var receivedCalls: [ReceivedCall] = []

    nonisolated init(results: [Result<String, Error>]) {
        self.pending = results
    }

    func process(
        structuredText: String,
        mode: Mode,
        spellingHints: SpellingHints,
        apiKey: String,
        parameterValues: [String: String]
    ) async throws -> String {
        receivedCalls.append(
            ReceivedCall(
                structuredText: structuredText,
                modeID: mode.id,
                spellingHints: spellingHints,
                apiKey: apiKey,
                parameterValues: parameterValues
            )
        )
        guard !pending.isEmpty else {
            throw TestError.outOfScriptedResults
        }
        let next = pending.removeFirst()
        switch next {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    enum TestError: Error, LocalizedError {
        case outOfScriptedResults

        var errorDescription: String? {
            "ScriptedAIProcessing: no more scripted results"
        }
    }
}
