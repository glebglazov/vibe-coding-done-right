import Foundation
import os
@testable import vcdr_ios

/// Scriptable fake `LLMProvider` for driving the factory / FallbackProvider
/// suites without touching the network. The attempt counter is lock-guarded so
/// it stays correct across the timeout race task group inside FallbackProvider.
/// Uses `OSAllocatedUnfairLock` because its `withLock` is async-context-safe,
/// unlike `NSLock.lock()`.
final class FakeLLMProvider: LLMProvider {
    enum Behavior: Sendable {
        /// Return `output` on every call.
        case alwaysSucceed(output: String)
        /// Throw on the first `failures` calls, then return `output`.
        case succeedAfter(failures: Int, output: String)
        /// Throw on every call.
        case alwaysThrow
        /// Sleep far past any realistic timeout (never returns within a budget).
        case hang
    }

    struct FakeError: Error {}

    let displayName: String
    private let behavior: Behavior
    private let attemptCount = OSAllocatedUnfairLock(initialState: 0)

    init(displayName: String = "Fake", behavior: Behavior) {
        self.displayName = displayName
        self.behavior = behavior
    }

    /// Number of times `process` has been entered.
    var attempts: Int {
        attemptCount.withLock { $0 }
    }

    func process(text: String, systemPrompt: String) async throws -> String {
        let attempt = attemptCount.withLock { count -> Int in
            count += 1
            return count
        }

        switch behavior {
        case .alwaysSucceed(let output):
            return output
        case .succeedAfter(let failures, let output):
            if attempt <= failures { throw FakeError() }
            return output
        case .alwaysThrow:
            throw FakeError()
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            return ""
        }
    }
}
