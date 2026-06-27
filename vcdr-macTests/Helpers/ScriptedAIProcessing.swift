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
/// Implemented as an actor because `AIProcessingPort` is `Sendable` and this
/// type holds mutable state.
actor ScriptedAIProcessing: AIProcessingPort {

    struct ReceivedCall: Equatable, Sendable {
        let structuredText: String
        let modeID: UUID
        let apiKey: String
        let parameterValues: [String: String]
    }

    private var pending: [Result<String, Error>]
    private(set) var receivedCalls: [ReceivedCall] = []

    init(results: [Result<String, Error>]) {
        self.pending = results
    }

    func process(
        structuredText: String,
        mode: Mode,
        apiKey: String,
        parameterValues: [String: String]
    ) async throws -> String {
        receivedCalls.append(
            ReceivedCall(
                structuredText: structuredText,
                modeID: mode.id,
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
