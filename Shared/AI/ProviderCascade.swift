import Foundation

/// The shared `Provider Cascade`: retry the primary up to `maxAttempts` (1 for
/// on-device, more for cloud) within `timeout`, racing each call against the
/// remaining budget; on exhaustion fall through to `fallback` once.
/// Throws `AITimedOut` when the budget is spent with no terminal error, or
/// rethrows the primary's last error otherwise — so the caller can substitute
/// local text and map the outcome onto its status. `fallback` may be nil
/// (no on-device fallback configured); a nil fallback simply rethrows the last
/// error, with no special-casing.
///
/// Semantics are byte-for-byte identical to the platform `FallbackProvider`
/// copies this consolidates. The cascade receives its primary, fallback, attempt
/// limit, and timeout from platform AI Provider Selection — it never reads
/// Mode, AI Prompt Mode, or any settings itself.
struct ProviderCascade: LLMAdapter {
    let primary: any LLMAdapter
    let fallback: (any LLMAdapter)?
    let maxAttempts: Int
    let timeout: Duration

    var displayName: String { primary.displayName }

    /// Thrown when the primary's time budget is spent without a terminal error
    /// and no fallback produced a result.
    struct AITimedOut: Error {}

    func process(text: String, systemPrompt: String) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        let attempts = max(1, maxAttempts)
        var lastError: Error?

        for attempt in 1...attempts {
            // Budget already spent before this attempt → timeout outcome.
            guard ContinuousClock.now < deadline else {
                return try await fallbackOr(throwing: AITimedOut(), text: text, systemPrompt: systemPrompt)
            }
            let remaining = deadline - ContinuousClock.now

            do {
                if let result = try await race(text: text, systemPrompt: systemPrompt, within: remaining) {
                    return result
                }
                // Sleep won the race — the call overran the remaining budget.
                return try await fallbackOr(throwing: AITimedOut(), text: text, systemPrompt: systemPrompt)
            } catch is CancellationError {
                // A cancelled call gives up to the fallback / local text rather
                // than propagating.
                return try await fallbackOr(throwing: AITimedOut(), text: text, systemPrompt: systemPrompt)
            } catch {
                lastError = error
                if attempt == attempts {
                    return try await fallbackOr(throwing: error, text: text, systemPrompt: systemPrompt)
                }
                // Otherwise loop: a fast error retries within the budget.
            }
        }

        return try await fallbackOr(throwing: lastError ?? AITimedOut(), text: text, systemPrompt: systemPrompt)
    }

    /// Races the primary call against a `remaining`-long sleep. Returns the
    /// primary's text, or `nil` if the timeout sentinel won the race.
    private func race(text: String, systemPrompt: String, within remaining: Duration) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { [primary] in
                try await primary.process(text: text, systemPrompt: systemPrompt)
            }
            group.addTask {
                try await Task.sleep(for: remaining)
                return nil // timeout sentinel
            }
            for try await result in group {
                group.cancelAll()
                return result
            }
            return nil
        }
    }

    /// Tries the fallback once (all its errors swallowed → fall through). If it
    /// has no result, rethrows `error` for the caller to classify.
    private func fallbackOr(throwing error: Error, text: String, systemPrompt: String) async throws -> String {
        if let fallback, let result = try? await fallback.process(text: text, systemPrompt: systemPrompt) {
            return result
        }
        throw error
    }
}
