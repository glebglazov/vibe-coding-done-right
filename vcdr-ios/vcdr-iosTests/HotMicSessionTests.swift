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

    @Test("teardown fails closed: readiness still closes when audio release fails")
    func teardownFailsClosedOnAudioReleaseFailure() async {
        let env = makeEnv(policy: .fiveMinutes)
        env.engine.endHotSessionError = FakeAudioReleaseError()

        await env.session.start()
        await settle()

        #expect(env.channel.isAppLikelyAlive())
        #expect(env.presence.isShown)

        env.clock.advance() // idle window elapses → teardown with a failing release
        await waitUntil { env.engine.endHotSessionCalls == 1 }

        // Audio release threw, but the user-visible readiness signals must close:
        // the Heartbeat goes stale (keyboard falls back to Deep-Link Fallback)
        // and Mic Presence stops advertising readiness.
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

    @Test("automatic prewarm skips audio setup when permission is unresolved")
    func automaticPrewarmDoesNotRequestPermission() async {
        let env = makeEnv(policy: .never)

        await env.session.prewarmIfPermitted()

        #expect(env.engine.permissionRequests == 0)
        #expect(env.engine.prepareSessionCalls == 0)
        #expect(env.engine.prepareEngineCalls == 0)
        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.engine.isHot)
    }

    @Test("automatic warm-session renewal skips unresolved microphone permission")
    func automaticRenewalDoesNotRequestPermission() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.startIfPermitted()

        #expect(env.engine.permissionRequests == 0)
        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.engine.isHot)
    }

    @Test("foreground renewal does not start a cold engine")
    func renewalDoesNotStartColdEngine() async {
        let env = makeEnv(policy: .fiveMinutes)
        env.engine.hasMicrophonePermission = true

        await env.session.renewIfAlive()

        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.engine.isHot)
    }

    @Test(".never prepares the engine without warming when permission is already granted")
    func neverPolicyDoesNotWarm() async {
        let env = makeEnv(policy: .never)
        env.engine.hasMicrophonePermission = true

        await env.session.prewarmIfPermitted()

        #expect(env.engine.permissionRequests == 0)
        #expect(env.engine.prepareSessionCalls == 1)
        #expect(env.engine.prepareEngineCalls == 1)
        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.engine.isHot)

        await env.session.start()

        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.channel.isAppLikelyAlive())
        #expect(env.presence.startCalls == 0)
        #expect(!env.presence.isShown)
    }

    @Test("finite policy preparation defers warming to start")
    func finitePrewarmDefersWarming() async {
        let env = makeEnv(policy: .fiveMinutes)
        env.engine.hasMicrophonePermission = true

        await env.session.prewarmIfPermitted()

        #expect(env.engine.prepareSessionCalls == 1)
        #expect(env.engine.prepareEngineCalls == 1)
        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())
        #expect(env.presence.startCalls == 0)
    }

    @Test(".never releases the engine as soon as it hears that capture has ended")
    func neverPolicyTearsDownOnStop() async {
        let env = makeEnv(policy: .never)
        env.engine.isHot = true
        env.engine.isRecording = true
        env.session.recordingStarted()
        await settle()
        #expect(env.presence.isShown)

        env.session.recordingStopped()
        await settle()
        #expect(env.engine.endHotSessionCalls == 0)

        env.engine.isRecording = false
        env.session.recordingStopped()
        await waitUntil { env.engine.endHotSessionCalls == 1 }

        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())
        #expect(!env.presence.isShown)
        #expect(env.clock.sleepCount == 0)
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
        await env.session.policyChanged()
        await waitUntil { env.engine.endHotSessionCalls == 1 }

        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())

        // Drain the now-cancelled finite sleeper so no continuation leaks.
        env.clock.advance()
        await settle()
    }

    @Test("opting into a warm policy does not start a cold session")
    func policyChangeFromNeverDoesNotStartColdSession() async {
        let env = makeEnv(policy: .never)

        env.holder.value = .fiveMinutes
        await env.session.policyChanged()
        await settle()

        #expect(env.engine.startHotSessionCalls == 0)
        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())
        #expect(env.presence.startCalls == 0)
    }

    @Test("decreasing finite policy keeps original idle start")
    func policyDecreaseKeepsOriginalIdleStart() async {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let env = makeEnv(policy: .tenMinutes, now: { fakeNow })

        await env.session.start()
        await settle()

        let originalDeadline = Date(timeIntervalSince1970: TimeInterval(HotSessionTimeout.tenMinutes.rawValue))
        #expect(env.session.idleDeadline == originalDeadline)

        fakeNow = Date(timeIntervalSince1970: 240)
        env.holder.value = .fiveMinutes
        await env.session.policyChanged()
        await settle()

        let shortenedDeadline = Date(timeIntervalSince1970: TimeInterval(HotSessionTimeout.fiveMinutes.rawValue))
        #expect(env.session.idleDeadline == shortenedDeadline)
        #expect(env.engine.isHot)

        env.clock.advance()
        await waitUntil { env.engine.endHotSessionCalls == 1 }
        #expect(!env.engine.isHot)
    }

    @Test("decreasing finite policy tears down when new deadline already passed")
    func expiredPolicyDecreaseTearsDownImmediately() async {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let env = makeEnv(policy: .tenMinutes, now: { fakeNow })

        await env.session.start()
        await settle()
        #expect(env.engine.isHot)

        fakeNow = Date(timeIntervalSince1970: TimeInterval(HotSessionTimeout.fiveMinutes.rawValue) + 1)
        env.holder.value = .fiveMinutes
        await env.session.policyChanged()
        await waitUntil { env.engine.endHotSessionCalls == 1 }

        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())
        await waitUntil { env.presence.stopCalls == 1 }
    }

    @Test("increasing finite policy does not extend the active deadline")
    func policyIncreaseDoesNotExtendActiveDeadline() async {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let env = makeEnv(policy: .fiveMinutes, now: { fakeNow })

        await env.session.start()
        await settle()

        let originalDeadline = Date(timeIntervalSince1970: TimeInterval(HotSessionTimeout.fiveMinutes.rawValue))
        #expect(env.session.idleDeadline == originalDeadline)

        fakeNow = Date(timeIntervalSince1970: 60)
        env.holder.value = .tenMinutes
        await env.session.policyChanged()
        await settle()

        #expect(env.session.idleDeadline == originalDeadline)
        #expect(env.engine.isHot)

        env.clock.advance()
        await waitUntil { env.engine.endHotSessionCalls == 1 }
        #expect(!env.engine.isHot)
    }

    @Test("post-capture stop starts finite warmth with the configured deadline")
    func postCaptureStopStartsFiniteWarmthWithDeadline() async {
        let fixedNow = Date(timeIntervalSince1970: 2_000)
        let env = makeEnv(policy: .fiveMinutes, now: { fixedNow })

        env.engine.isHot = true
        env.engine.isRecording = true
        env.session.recordingStarted()
        await settle()

        #expect(env.presence.isShown)
        #expect(env.session.idleDeadline == nil)

        env.engine.isRecording = false
        env.session.recordingStopped()
        await settle()

        let expected = fixedNow.addingTimeInterval(TimeInterval(HotSessionTimeout.fiveMinutes.rawValue))
        #expect(env.session.idleDeadline == expected)
        #expect(env.presence.isShown)
        #expect(env.channel.isAppLikelyAlive())
        #expect(env.clock.sleepCount == 1)

        env.clock.advance()
        await waitUntil { env.engine.endHotSessionCalls == 1 }
    }

    @Test("reset tears down session signals without refreshing the timeout")
    func resetTearsDownWithoutRefreshingTimeout() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()

        #expect(env.engine.isHot)
        #expect(env.channel.isAppLikelyAlive())
        #expect(env.presence.isShown)
        #expect(env.clock.sleepCount == 1)

        env.session.reset()
        await waitUntil { env.presence.stopCalls == 1 }

        #expect(env.engine.endHotSessionCalls == 1)
        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())
        #expect(!env.presence.isShown)
        #expect(env.clock.sleepCount == 1)

        env.clock.advance()
        await settle()
        #expect(env.engine.endHotSessionCalls == 1)
    }

    @Test("arming cancellation without a prior warm window releases mic presence immediately")
    func armingCancellationWithoutPriorWindowReleasesImmediately() async {
        let env = makeEnv(policy: .fiveMinutes)

        env.session.recordIntentStarted()
        env.engine.isHot = true
        env.session.recordIntentCancelledBeforeCapture()
        await waitUntil { env.engine.endHotSessionCalls == 1 }

        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())
        #expect(!env.presence.isShown)
        #expect(env.presence.startCalls == 0)
        #expect(env.clock.sleepCount == 0)
    }

    @Test("arming cancellation restores prior finite deadline without extending it")
    func armingCancellationRestoresPriorDeadlineWithoutExtending() async {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let env = makeEnv(policy: .fiveMinutes, now: { fakeNow })

        await env.session.start()
        await settle()

        let originalDeadline = Date(timeIntervalSince1970: TimeInterval(HotSessionTimeout.fiveMinutes.rawValue))
        #expect(env.session.idleDeadline == originalDeadline)

        fakeNow = Date(timeIntervalSince1970: 60)
        env.session.recordIntentStarted()
        await settle()

        env.session.recordIntentCancelledBeforeCapture()
        await settle()

        #expect(env.engine.isHot)
        #expect(env.presence.isShown)
        #expect(env.session.idleDeadline == originalDeadline)
        #expect(env.clock.sleepCount == 2)

        env.clock.advance()
        await waitUntil { env.engine.endHotSessionCalls == 1 }
        #expect(!env.engine.isHot)
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

    @Test("foreground re-entry after idle window has elapsed tears down immediately")
    func startAfterDeadlineTearsDown() async {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let env = makeEnv(policy: .fiveMinutes, now: { fakeNow })

        await env.session.start()
        await settle()
        #expect(env.engine.isHot)

        // Simulate wall clock advancing past the full timeout while backgrounded.
        fakeNow = Date(timeIntervalSince1970: TimeInterval(HotSessionTimeout.fiveMinutes.rawValue) + 1)

        // Foreground re-entry: start() should detect expiry and tear down without sleeping.
        await env.session.start()
        await waitUntil { env.engine.endHotSessionCalls == 1 }

        #expect(!env.engine.isHot)
        #expect(!env.channel.isAppLikelyAlive())
        await waitUntil { env.presence.stopCalls == 1 }

        // Drain any parked sleepers from the initial arm.
        env.clock.advance()
        await settle()
    }

    @Test("foreground re-entry mid-window uses remaining time, not the full duration")
    func startMidWindowUsesRemainingTime() async {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let env = makeEnv(policy: .fiveMinutes, now: { fakeNow })

        await env.session.start()
        await settle()
        #expect(env.engine.isHot)
        let sleepsAfterFirstStart = env.clock.sleepCount

        // Advance wall clock by 1 minute — still within the 5-minute window.
        fakeNow = Date(timeIntervalSince1970: 60)

        // Foreground re-entry: should schedule a new sleep for the remaining ~4 min.
        await env.session.start()
        await settle()
        #expect(env.clock.sleepCount == sleepsAfterFirstStart + 1)

        // The session is still alive; it tears down only when the remaining sleep elapses.
        #expect(env.engine.isHot)
        env.clock.advance()
        await waitUntil { env.engine.endHotSessionCalls == 1 }
        #expect(!env.engine.isHot)
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

    @Test("finite policy keeps the Presence Deadline to itself and reports reachability")
    func finitePolicyKeepsDeadlineOutOfPresence() async {
        let fixedNow = Date(timeIntervalSince1970: 1000)
        let beat = TestClock()
        let env = makeEnv(policy: .fiveMinutes, heartbeatClock: beat, now: { fixedNow })

        await env.session.start()
        await settle()

        // The warm window is the session's business; presence is handed no
        // deadline it could surrender its ability to correct the card for.
        #expect(env.session.idleDeadline == fixedNow.addingTimeInterval(TimeInterval(HotSessionTimeout.fiveMinutes.rawValue)))
        #expect(env.presence.isShown)

        beat.advance()
        await settle()
        #expect(env.presence.isShown)
        #expect(env.presence.startCalls == 1)

        // Cleanup: drain the parked idle and heartbeat sleepers.
        env.clock.advance()
        beat.advance()
        await settle()
    }

    @Test(".always keeps presence live and the heartbeat alive")
    func alwaysPolicyKeepsPresenceLive() async {
        let env = makeEnv(policy: .always)

        await env.session.start()
        await settle()

        #expect(env.presence.isShown)
        // Reachability contract is unweakened: heartbeat still signals alive.
        #expect(env.channel.isAppLikelyAlive())
    }

    @Test("recording keeps reachability up so readiness can't expire mid-capture")
    func recordingKeepsReachability() async {
        let env = makeEnv(policy: .fiveMinutes)

        await env.session.start()
        await settle()
        #expect(env.presence.isShown)

        env.engine.isRecording = true
        env.session.recordingStarted()
        await settle()

        #expect(env.presence.isShown)
        #expect(env.presence.stopCalls == 0)
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

    /// `heartbeatClock` defaults to the real clock so tests that don't drive
    /// beats leave no parked sleeper behind; the ones that do pass their own.
    private func makeEnv(
        policy: HotSessionTimeout,
        heartbeatClock: HotMicClock? = nil,
        now: (() -> Date)? = nil
    ) -> Env {
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
            heartbeatClock: heartbeatClock,
            policy: { holder.value },
            now: now
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
    var hasMicrophonePermission = false

    var permissionRequests = 0
    var prepareSessionCalls = 0
    var prepareEngineCalls = 0
    var startHotSessionCalls = 0
    var endHotSessionCalls = 0
    /// When false, `startHotSession` reports failure and leaves the engine cold.
    var startSucceeds = true
    /// When set, `endHotSession` still completes its local teardown (clears
    /// `isHot`) but throws — modeling a partial audio-release failure so tests
    /// can assert the session fails closed.
    var endHotSessionError: (any Error)?

    func requestMicrophonePermission() async -> Bool {
        permissionRequests += 1
        hasMicrophonePermission = true
        return true
    }

    func prepareAudioSession() async { prepareSessionCalls += 1 }
    func prepareEngine() async { prepareEngineCalls += 1 }

    func startHotSession() async -> Bool {
        startHotSessionCalls += 1
        if startSucceeds { isHot = true }
        return startSucceeds
    }

    func endHotSession() throws {
        endHotSessionCalls += 1
        isHot = false
        isRecording = false
        if let endHotSessionError { throw endHotSessionError }
    }
}

/// Stand-in for a partial audio-release failure (e.g. the audio session
/// refusing to deactivate) surfaced by `endHotSession`.
struct FakeAudioReleaseError: Error {}

@MainActor
final class SpyPresence: MicPresence {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var isShown = false

    func reachabilityChanged(_ reachable: Bool) {
        guard reachable != isShown else { return }
        isShown = reachable
        if reachable {
            startCalls += 1
        } else {
            stopCalls += 1
        }
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
