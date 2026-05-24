import Testing
@testable import vcdr_ios

/// Drives `FallbackProvider` with the scriptable `FakeLLMProvider` so the
/// cascade / retry / timeout logic is exercised without a network.
@Suite("FallbackProvider cascade")
struct FallbackProviderTests {

    private let shortTimeout: Duration = .seconds(2)

    @Test("primary succeeds on first attempt — no fallback used")
    func primaryFirstTry() async throws {
        let primary = FakeLLMProvider(behavior: .alwaysSucceed(output: "primary"))
        let fallback = FakeLLMProvider(behavior: .alwaysSucceed(output: "fallback"))
        let sut = FallbackProvider(primary: primary, fallback: fallback, maxAttempts: 3, timeout: shortTimeout)

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "primary")
        #expect(primary.attempts == 1)
        #expect(fallback.attempts == 0)
    }

    @Test("primary fails twice then succeeds within the budget")
    func retryThenSucceed() async throws {
        let primary = FakeLLMProvider(behavior: .succeedAfter(failures: 2, output: "primary"))
        let sut = FallbackProvider(primary: primary, fallback: nil, maxAttempts: 3, timeout: shortTimeout)

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "primary")
        #expect(primary.attempts == 3)
    }

    @Test("cloud exhausts retries then AFM fallback succeeds")
    func cloudExhaustedThenFallback() async throws {
        let primary = FakeLLMProvider(behavior: .alwaysThrow)
        let fallback = FakeLLMProvider(behavior: .alwaysSucceed(output: "fallback"))
        let sut = FallbackProvider(primary: primary, fallback: fallback, maxAttempts: 3, timeout: shortTimeout)

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "fallback")
        #expect(primary.attempts == 3)
        #expect(fallback.attempts == 1)
    }

    @Test("primary and fallback both fail — rethrows the primary's error")
    func totalFailureRethrows() async {
        let primary = FakeLLMProvider(behavior: .alwaysThrow)
        let fallback = FakeLLMProvider(behavior: .alwaysThrow)
        let sut = FallbackProvider(primary: primary, fallback: fallback, maxAttempts: 3, timeout: shortTimeout)

        await #expect(throws: FakeLLMProvider.FakeError.self) {
            _ = try await sut.process(text: "x", systemPrompt: "y")
        }
    }

    @Test("primary hangs past the budget — throws AITimedOut, no fallback")
    func primaryTimesOut() async {
        let primary = FakeLLMProvider(behavior: .hang)
        let sut = FallbackProvider(primary: primary, fallback: nil, maxAttempts: 3, timeout: .milliseconds(200))

        await #expect(throws: FallbackProvider.AITimedOut.self) {
            _ = try await sut.process(text: "x", systemPrompt: "y")
        }
    }

    @Test("primary hangs but AFM fallback rescues — returns fallback output")
    func timeoutThenFallback() async throws {
        let primary = FakeLLMProvider(behavior: .hang)
        let fallback = FakeLLMProvider(behavior: .alwaysSucceed(output: "fallback"))
        let sut = FallbackProvider(primary: primary, fallback: fallback, maxAttempts: 3, timeout: .milliseconds(200))

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "fallback")
        #expect(fallback.attempts == 1)
    }

    @Test("apple primary gets a single attempt (no retry)")
    func appleSingleAttempt() async {
        let primary = FakeLLMProvider(behavior: .alwaysThrow)
        // maxAttempts == 1 models the on-device (.apple) primary.
        let sut = FallbackProvider(primary: primary, fallback: nil, maxAttempts: 1, timeout: shortTimeout)

        await #expect(throws: FakeLLMProvider.FakeError.self) {
            _ = try await sut.process(text: "x", systemPrompt: "y")
        }
        #expect(primary.attempts == 1)
    }
}
