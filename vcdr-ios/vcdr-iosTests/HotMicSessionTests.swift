import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("HotMicSession")
struct HotMicSessionTests {

    // MARK: - Tests

    @Test("finite policy tears the session down after the idle window")
    func idleTimeoutTearsDown() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()

        #expect(env.engine.isHot)
        #expect(env.channel.isAppLikelyAlive())
        #expect(env.presence.isShown)
        #expect(env.clock.sleepCount == 1) // idle timer is armed and parked

        env.clock.advance() // idle window elapses
        await waitUntil { env.engine.endHotSessionCalls == 1 }

        // Teardown is atomic — engine, heartbeat, and presence all go down.
        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())
        await waitUntil { env.presence.stopCalls == 1 }
        #expect(!env.presence.isShown)
    }

    @Test("a recording cancels the pending teardown")
    func recordingCancelsIdleTimer() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()

        env.engine.isRecording = true
        env.session.recordingStarted()
        await settle()

        env.clock.advance() // window elapses, but the timer was cancelled
        await settle()

        #expect(env.engine.isHot)
        #expect(env.engine.endHotSessionCalls == 0)
    }

    @Test("re-arms the timer after a recording stops")
    func reArmsAfterStop() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()

        env.engine.isRecording = true
        env.session.recordingStarted()
        await settle()

        env.engine.isRecording = false
        env.session.recordingStopped()
        await settle()
        #expect(env.clock.sleepCount >= 1)

        env.clock.advance()
        await waitUntil { env.engine.endHotSessionCalls == 1 }
        #expect(!env.engine.isHot)
    }

    @Test(".never prepares the engine but never warms it (regression: orange mic at launch)")
    func neverPolicyDoesNotWarm() async {
        let env = makeEnv(policy: .never)

        await env.session.prewarm()

        // Permission + session + engine are prepared (the launch-latency win)…
        #expect(env.engine.permissionRequests == 1)
        #expect(env.engine.prepareSessionCalls == 1)
        #expect(env.engine.prepareEngineCalls == 1)
        // …but the engine is NOT started, so no mic indicator appears.
        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.engine.isHot)

        await env.session.start()

        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.channel.isAppLikelyAlive())
        #expect(env.presence.startCalls == 0)
        #expect(!env.presence.isShown)
    }

    @Test("finite policy warms the engine during prewarm, deferring heartbeat/presence")
    func finitePrewarmWarms() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.prewarm()

        #expect(env.engine.startHotSessionCalls == 1)
        #expect(env.engine.isHot)
        // prewarm warms the engine only; heartbeat + presence are start()'s job.
        #expect(!env.channel.isAppLikelyAlive())
        #expect(env.presence.startCalls == 0)
    }

    @Test(".always keeps the session alive indefinitely")
    func alwaysNeverTearsDown() async {
        let env = makeEnv(policy: .always)

        await env.session.start()
        await settle()

        #expect(env.engine.isHot)
        #expect(env.channel.isAppLikelyAlive())
        #expect(env.presence.isShown)
        #expect(env.clock.sleepCount == 0) // no idle timer scheduled

        env.clock.advance()
        await settle()

        #expect(env.engine.isHot)
        #expect(env.engine.endHotSessionCalls == 0)
    }

    @Test("switching the policy to .never tears the session down immediately")
    func policyChangeToNeverTearsDown() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()
        #expect(env.engine.isHot)

        env.holder.value = .never
        env.session.policyChanged()
        await waitUntil { env.engine.endHotSessionCalls == 1 }

        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())

        // Drain the now-cancelled finite sleeper so no continuation leaks.
        env.clock.advance()
        await settle()
    }

    @Test("start is idempotent — presence is shown once across repeated calls")
    func startIsIdempotent() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()
        await env.session.start()
        await settle()

        #expect(env.presence.startCalls == 1)
        #expect(env.channel.isAppLikelyAlive())
        #expect(env.engine.isHot)

        // Cleanup: cancel the live timer and drain any parked sleepers.
        env.engine.isRecording = true
        env.session.recordingStarted()
        await settle()
        env.clock.advance()
        await settle()
    }

    @Test("finite policy keeps presence visible until session teardown")
    func finitePolicyKeepsPresenceUntilTeardown() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()

        #expect(env.presence.isShown)
        #expect(env.presence.stopCalls == 0)

        env.clock.advance()
        await waitUntil { env.presence.stopCalls == 1 }

        #expect(!env.presence.isShown)
    }

    @Test("recording keeps presence visible")
    func recordingKeepsPresenceVisible() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()
        #expect(env.presence.isShown)

        env.engine.isRecording = true
        env.session.recordingStarted()
        await settle()

        #expect(env.presence.isShown)
    }

    // MARK: - Environment

    @MainActor
    struct Env {
        let engine: FakeWarmEngine
        let presence: SpyPresence
        let clock: TestClock
        let channel: KeyboardChannel
        let holder: PolicyHolder
        let session: HotMicSession
    }

    private func makeEnv(policy: HotSessionTimeout) -> Env {
        let engine = FakeWarmEngine()
        let presence = SpyPresence()
        let clock = TestClock()
        let suite = "HotMicSessionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let channel = KeyboardChannel(defaults: defaults)
        let holder = PolicyHolder(value: policy)
        let session = HotMicSession(
            engine: engine,
            presence: presence,
            keyboard: channel,
            clock: clock,
            policy: { holder.value }
        )
        return Env(
            engine: engine,
            presence: presence,
            clock: clock,
            channel: channel,
            holder: holder,
            session: session
        )
    }

    /// Lets enqueued MainActor jobs (resumed idle tasks, child presence tasks)
    /// run to a quiescent point before asserting.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// Polls a condition across MainActor turns — robust against how many hops
    /// a resumed continuation needs before its effect is observable.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }
}

// MARK: - Test doubles

@MainActor
final class PolicyHolder {
    var value: HotSessionTimeout
    init(value: HotSessionTimeout) { self.value = value }
}

/// In-memory `WarmEngine`. Records the calls `HotMicSession` makes so tests can
/// assert what was driven, and models `isHot` the way `AudioRecorder` does.
@MainActor
final class FakeWarmEngine: WarmEngine {
    var isHot = false
    var isRecording = false

    var permissionRequests = 0
    var prepareSessionCalls = 0
    var prepareEngineCalls = 0
    var startHotSessionCalls = 0
    var endHotSessionCalls = 0
    /// When false, `startHotSession` reports failure and leaves the engine cold.
    var startSucceeds = true

    func requestMicrophonePermission() async -> Bool {
        permissionRequests += 1
        return true
    }

    func prepareAudioSession() async { prepareSessionCalls += 1 }
    func prepareEngine() async { prepareEngineCalls += 1 }

    func startHotSession() async -> Bool {
        startHotSessionCalls += 1
        if startSucceeds { isHot = true }
        return startSucceeds
    }

    func endHotSession() {
        endHotSessionCalls += 1
        isHot = false
        isRecording = false
    }
}

/// Spy `MicPresence` that mirrors `HotMicActivityController`'s idempotency: a
/// second `start()` while already shown is a no-op, so `startCalls` counts
/// distinct presentations.
@MainActor
final class SpyPresence: MicPresence {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var isShown = false

    func start() async {
        guard !isShown else { return }
        isShown = true
        startCalls += 1
    }

    func stop() async {
        guard isShown else { return }
        stopCalls += 1
        isShown = false
    }
}

/// Virtual clock for the idle-timeout machine. `sleep(for:)` parks until
/// `advance()` resumes every pending wait — so timeout transitions are
/// deterministic without real waits.
@MainActor
final class TestClock: HotMicClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private(set) var sleepCount = 0

    func sleep(for duration: Duration) async {
        sleepCount += 1
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if Task.isCancelled {
                cont.resume()
            } else {
                sleepers.append(cont)
            }
        }
    }

    /// Simulate time passing: resume every currently-parked sleep.
    func advance() {
        let parked = sleepers
        sleepers.removeAll()
        parked.forEach { $0.resume() }
    }
}
