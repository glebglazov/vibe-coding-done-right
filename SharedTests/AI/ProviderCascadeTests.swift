import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Drives `ProviderCascade` with the scriptable `FakeLLMAdapter` so the
/// cascade / retry / timeout logic is exercised without a network. Owns the
/// cascade behavior suite for both platforms — the duplicated platform
/// `FallbackProviderTests` are removed once this SharedTests suite is hosted.
@Suite("ProviderCascade")
struct ProviderCascadeTests {

    private let shortTimeout: Duration = .seconds(2)

    @Test("primary succeeds on first attempt — no fallback used")
    func primaryFirstTry() async throws {
        let primary = FakeLLMAdapter(behavior: .alwaysSucceed(output: "primary"))
        let fallback = FakeLLMAdapter(behavior: .alwaysSucceed(output: "fallback"))
        let sut = ProviderCascade(primary: primary, fallback: fallback, maxAttempts: 3, timeout: shortTimeout)

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "primary")
        #expect(primary.attempts == 1)
        #expect(fallback.attempts == 0)
    }

    @Test("primary fails twice then succeeds within the budget")
    func retryThenSucceed() async throws {
        let primary = FakeLLMAdapter(behavior: .succeedAfter(failures: 2, output: "primary"))
        let sut = ProviderCascade(primary: primary, fallback: nil, maxAttempts: 3, timeout: shortTimeout)

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "primary")
        #expect(primary.attempts == 3)
    }

    @Test("cloud exhausts retries then fallback succeeds")
    func cloudExhaustedThenFallback() async throws {
        let primary = FakeLLMAdapter(behavior: .alwaysThrow)
        let fallback = FakeLLMAdapter(behavior: .alwaysSucceed(output: "fallback"))
        let sut = ProviderCascade(primary: primary, fallback: fallback, maxAttempts: 3, timeout: shortTimeout)

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "fallback")
        #expect(primary.attempts == 3)
        #expect(fallback.attempts == 1)
    }

    @Test("primary and fallback both fail — rethrows the primary's error")
    func totalFailureRethrows() async {
        let primary = FakeLLMAdapter(behavior: .alwaysThrow)
        let fallback = FakeLLMAdapter(behavior: .alwaysThrow)
        let sut = ProviderCascade(primary: primary, fallback: fallback, maxAttempts: 3, timeout: shortTimeout)

        await #expect(throws: FakeLLMAdapter.FakeError.self) {
            _ = try await sut.process(text: "x", systemPrompt: "y")
        }
    }

    @Test("nil fallback rethrows the primary's last error")
    func nilFallbackRethrows() async {
        let primary = FakeLLMAdapter(behavior: .alwaysThrow)
        let sut = ProviderCascade(primary: primary, fallback: nil, maxAttempts: 3, timeout: shortTimeout)

        await #expect(throws: FakeLLMAdapter.FakeError.self) {
            _ = try await sut.process(text: "x", systemPrompt: "y")
        }
        #expect(primary.attempts == 3)
    }

    @Test("primary hangs past the budget — throws AITimedOut, no fallback")
    func primaryTimesOut() async {
        let primary = FakeLLMAdapter(behavior: .hang)
        let sut = ProviderCascade(primary: primary, fallback: nil, maxAttempts: 3, timeout: .milliseconds(200))

        await #expect(throws: ProviderCascade.AITimedOut.self) {
            _ = try await sut.process(text: "x", systemPrompt: "y")
        }
    }

    @Test("primary hangs but fallback rescues — returns fallback output")
    func timeoutThenFallback() async throws {
        let primary = FakeLLMAdapter(behavior: .hang)
        let fallback = FakeLLMAdapter(behavior: .alwaysSucceed(output: "fallback"))
        let sut = ProviderCascade(primary: primary, fallback: fallback, maxAttempts: 3, timeout: .milliseconds(200))

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "fallback")
        #expect(fallback.attempts == 1)
    }

    @Test("cancelled primary call uses the fallback")
    func cancellationThenFallback() async throws {
        let primary = FakeLLMAdapter(behavior: .cancel)
        let fallback = FakeLLMAdapter(behavior: .alwaysSucceed(output: "fallback"))
        let sut = ProviderCascade(primary: primary, fallback: fallback, maxAttempts: 3, timeout: shortTimeout)

        let result = try await sut.process(text: "x", systemPrompt: "y")

        #expect(result == "fallback")
        #expect(primary.attempts == 1)
        #expect(fallback.attempts == 1)
    }

    @Test("cancelled primary call without fallback throws AITimedOut")
    func cancellationWithoutFallback() async {
        let primary = FakeLLMAdapter(behavior: .cancel)
        let sut = ProviderCascade(primary: primary, fallback: nil, maxAttempts: 3, timeout: shortTimeout)

        await #expect(throws: ProviderCascade.AITimedOut.self) {
            _ = try await sut.process(text: "x", systemPrompt: "y")
        }
        #expect(primary.attempts == 1)
    }

    @Test("on-device primary gets a single attempt (no retry)")
    func singleAttempt() async {
        let primary = FakeLLMAdapter(behavior: .alwaysThrow)
        // maxAttempts == 1 models the on-device primary.
        let sut = ProviderCascade(primary: primary, fallback: nil, maxAttempts: 1, timeout: shortTimeout)

        await #expect(throws: FakeLLMAdapter.FakeError.self) {
            _ = try await sut.process(text: "x", systemPrompt: "y")
        }
        #expect(primary.attempts == 1)
    }
}
