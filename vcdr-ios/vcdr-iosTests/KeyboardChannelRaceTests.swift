import Foundation
import Testing
@testable import vcdr_ios

/// The app and the keyboard as two processes over one App Group suite: each
/// side has its own `KeyboardChannel`, and only the defaults are shared. The
/// keyboard's command post reaches the app's command listener the way the
/// Darwin hop does.
@MainActor
@Suite("Keyboard Channel races", .serialized)
struct KeyboardChannelRaceTests {
    @Test("a stop right after START acknowledges the start, so the start check opens no deep link")
    func quickStopAcknowledgesTheStart() async throws {
        let env = TwoProcesses(transcript: "")
        let start = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }

        _ = env.keyboard.stopRecording(run)
        await env.waitUntil { env.app.readPhase() == .ended(.emptyResult) }

        // The 0.4 s start check runs now: the run has already ended, but the
        // app took the start command, so the keyboard opens no record link.
        #expect(env.reader.isAcknowledged(start))
        #expect(env.coordinator.activeRun == nil)
        #expect(env.app.readSnapshot()?.run?.id == run)
    }

    @Test("a late record deep link for a command the app already took starts nothing")
    func lateRecordDeepLinkStartsNothing() async throws {
        let env = TwoProcesses(transcript: "")
        let start = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        _ = env.keyboard.stopRecording(run)
        await env.waitUntil { env.app.readPhase() == .ended(.emptyResult) }

        #expect(!env.coordinator.handleRecordDeepLink(start))

        #expect(env.coordinator.activeRun == nil)
        #expect(env.app.readSnapshot()?.run?.id == run)
        #expect(env.app.readPhase() == .ended(.emptyResult))
    }

    @Test("a record link that follows its own Darwin start still sends the user back, and starts no second run")
    func lateRecordDeepLinkDuringItsRunStillReturns() async throws {
        let env = TwoProcesses(transcript: "")
        let start = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }

        #expect(env.coordinator.handleRecordDeepLink(start))

        #expect(env.coordinator.activeRun?.run.id == run)
        #expect(env.app.readSnapshot()?.run?.id == run)
    }

    /// Race R5: a stop that crossed a Discard finds the run already ended.
    @Test("a stop for a run that already ended changes nothing and reports no failure")
    func stopAfterTheRunEndedIsIgnored() async throws {
        let env = TwoProcesses(transcript: "hello world")
        _ = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        await env.waitUntil { env.engine.isRecording }
        env.keyboard.discardRecording(run)
        await env.waitUntil { env.app.readPhase() == .ended(.cancelled) }

        guard case .commandSent(let stop) = env.keyboard.stopRecording(run) else {
            Issue.record("Expected a Darwin stop")
            return
        }
        await env.waitUntil { env.reader.isAcknowledged(stop) }

        #expect(env.app.readPhase() == .ended(.cancelled))
        if case .error = env.coordinator.state {
            Issue.record("A stop with no run showed an error: \(env.coordinator.state)")
        }
    }

    /// Race S6: the stop acknowledgement timed out, so the command and the
    /// deep link both arrive, the link after the run ended.
    @Test("a late stop deep link leaves the run's terminal state on the wire")
    func lateStopDeepLinkKeepsTheTerminalState() async throws {
        let env = TwoProcesses(transcript: "")
        _ = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        guard case .commandSent(let stop) = env.keyboard.stopRecording(run) else {
            Issue.record("Expected a Darwin stop")
            return
        }
        await env.waitUntil { env.app.readPhase() == .ended(.emptyResult) }

        await env.coordinator.handleStopDeepLink(stop, run: run)
        await env.coordinator.handleStopDeepLink(CommandID(), run: run)

        #expect(env.app.readPhase() == .ended(.emptyResult))
        #expect(env.reader.refresh() == .flash(run, .emptyResult))
    }

    /// Race R6: one command slot kept only the last command, so a Discard
    /// followed by a stop delivered the text the user discarded.
    @Test("a Discard and a stop queued before the app reads are both taken, in order")
    func queuedCommandsAreAllTakenInOrder() async throws {
        let env = TwoProcesses(transcript: "hello world")
        _ = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        await env.waitUntil { env.engine.isRecording }

        env.quietKeyboard.discardRecording(run)
        _ = env.quietKeyboard.stopRecording(run)
        let queued = env.app.readCommands().suffix(2).map(\.id)
        env.postCommand()
        await env.waitUntil { queued.allSatisfy { env.reader.isAcknowledged($0) } }

        #expect(env.app.readSnapshot()?.handledCommands.suffix(2) == queued[...])
        await env.waitUntil { env.app.readPhase() == .ended(.cancelled) }
        #expect(env.app.readPhase() == .ended(.cancelled))
    }

    /// Race R8: the DISCARDED pill ignored the wire for its whole flash.
    @Test("a new run replaces the DISCARDED pill at once")
    func newRunReplacesTheDiscardedPill() async throws {
        let env = TwoProcesses(transcript: "hello world")
        _ = try #require(env.sendStart())
        let first = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        await env.waitUntil { env.engine.isRecording }
        env.keyboard.discardRecording(first)
        _ = try await env.keyboardSees { $0 == .flash(first, .cancelled) ? first : nil }

        #expect(await env.coordinator.startRecording(origin: .app) == .capturing)

        guard case .recording(let second) = env.reader.refresh(), second != first else {
            Issue.record("Expected the new run, got \(env.reader.shown)")
            return
        }
    }

    /// Race S5: the keyboard consumed the wire to idle, so its own next read
    /// cut the pill it had just started.
    @Test("a terminal pill survives the keyboard's next read and shows once per run")
    func terminalPillShowsOnceAndIsNotCut() async throws {
        let env = TwoProcesses(transcript: "")
        _ = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        _ = env.keyboard.stopRecording(run)
        _ = try await env.keyboardSees { $0 == .flash(run, .emptyResult) ? run : nil }

        #expect(env.reader.refresh() == .flash(run, .emptyResult))
        #expect(env.app.readPhase() == .ended(.emptyResult))

        var reappeared = KeyboardWireReader(channel: env.keyboard)
        #expect(reappeared.refresh() == .idle)
    }

    @Test("the stop poll inserts its run's Bundled Result once")
    func stopPollInsertsTheBundledResultOnce() async throws {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let env = TwoProcesses(transcript: "hello world")
        _ = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        await env.waitUntil { env.engine.isRecording }
        guard case .commandSent(let stop) = env.keyboard.stopRecording(run) else {
            Issue.record("Expected a Darwin stop")
            return
        }

        await env.waitUntil {
            if case .insert = env.reader.stopStep(for: stop, of: run, ackTimedOut: true) { return true }
            return false
        }
        guard case .insert(let text) = env.reader.stopStep(for: stop, of: run, ackTimedOut: true) else {
            Issue.record("Expected the Bundled Result")
            return
        }
        #expect(text.localizedCaseInsensitiveContains("hello world"))

        #expect(env.reader.didInsert(for: run) == .idle)
        #expect(env.reader.stopStep(for: stop, of: run, ackTimedOut: true) == .render)
        var reappeared = KeyboardWireReader(channel: env.keyboard)
        #expect(reappeared.refresh() == .idle)
    }

    @Test("a Discard older than its freshness window is dropped")
    func staleDiscardIsDropped() async throws {
        let env = TwoProcesses(transcript: "hello world")
        _ = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        await env.waitUntil { env.engine.isRecording }

        env.quietKeyboard.discardRecording(run, now: Date().addingTimeInterval(-KeyboardChannel.discardFreshnessWindow - 1))
        env.postCommand()
        try await Task.sleep(for: .milliseconds(200))

        #expect(env.coordinator.activeRun?.run.id == run)
        #expect(env.app.readPhase() == .recording)
    }

    @Test("the launch snapshot does not hide a run a deep link already began")
    func launchPublishKeepsADeepLinkRun() async throws {
        let env = TwoProcesses(transcript: "")
        let command = CommandID()

        #expect(env.coordinator.handleRecordDeepLink(command))
        await env.waitUntil { env.app.readPhase() == .recording }
        env.coordinator.keyboardWire.publishLaunch()

        #expect(env.app.readPhase() == .recording)
        #expect(env.reader.isAcknowledged(command))
    }

    @Test("a run in progress from an app that stopped running shows idle")
    func staleRunFromAGoneAppShowsIdle() {
        let env = TwoProcesses(transcript: "")
        let start = Date(timeIntervalSince1970: 10_000)
        let gone = KeyboardWirePublisher(channel: env.app, clock: TestClock(), now: { start })
        let run = RunID()
        gone.show(.transcribing, of: run)
        env.app.writeHeartbeat(alive: false)

        var reader = KeyboardWireReader(channel: env.keyboard)
        #expect(reader.refresh(now: start.addingTimeInterval(5)) == .transcribing(run))
        #expect(reader.refresh(now: start.addingTimeInterval(KeyboardChannel.heartbeatFreshnessWindow + 1)) == .idle)
    }

    @Test("a run the app keeps renewing stays shown with no Heartbeat")
    func renewedRunStaysShownWithoutAHeartbeat() async {
        let env = TwoProcesses(transcript: "")
        let clock = TestClock()
        let start = Date(timeIntervalSince1970: 10_000)
        let time = MutableDate(start)
        let wire = KeyboardWirePublisher(channel: env.app, clock: clock, now: { time.value })
        let run = RunID()
        wire.show(.transcribing, of: run)
        env.app.writeHeartbeat(alive: false)

        let later = start.addingTimeInterval(KeyboardChannel.heartbeatFreshnessWindow + 10)
        time.value = later.addingTimeInterval(-1)
        await env.waitUntil { clock.sleepCount == 1 }
        clock.advance()
        await env.waitUntil { env.app.readSnapshot()?.writtenAt == time.value }

        var reader = KeyboardWireReader(channel: env.keyboard)
        #expect(reader.refresh(now: later) == .transcribing(run))
    }

    @Test("under the Never timeout the keyboard shows Finalizing after the Heartbeat is cleared")
    func neverTimeoutFinalizingStaysShown() async throws {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let env = TwoProcesses(transcript: "hello", finishDelay: .seconds(1), policy: .never)
        env.app.writeHeartbeat(alive: true)
        _ = try #require(env.sendStart())
        let run = try await env.keyboardSees { if case .recording(let run) = $0 { run } else { nil } }
        await env.waitUntil { env.engine.isRecording }

        _ = env.keyboard.stopRecording(run)
        await env.waitUntil { env.app.readPhase() == .transcribing }

        #expect(!env.keyboard.isAppLikelyAlive())
        #expect(env.reader.refresh() == .transcribing(run))
        await env.waitUntil(timeout: .seconds(3)) { env.coordinator.activeRun == nil }
    }
}

// MARK: - Environment

@MainActor
private final class TwoProcesses {
    let engine = SpyWarmRecordingEngine()
    let app: KeyboardChannel
    /// The keyboard as it runs: each command posts.
    let keyboard: KeyboardChannel
    /// The keyboard writing commands the app has not heard of yet.
    let quietKeyboard: KeyboardChannel
    let coordinator: RecordingFlowCoordinator
    var reader: KeyboardWireReader

    init(transcript: String, finishDelay: Duration = .zero, policy: HotSessionTimeout? = nil) {
        engine.hasMicrophonePermission = true
        let suite = "KeyboardChannelRaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        app = KeyboardChannel(defaults: defaults)
        keyboard = KeyboardChannel(defaults: defaults, notify: { name in
            guard name == KeyboardChannel.commandNotificationName else { return }
            NotificationCenter.default.post(name: .darwinCommand, object: nil)
        })
        quietKeyboard = KeyboardChannel(defaults: defaults)
        reader = KeyboardWireReader(channel: keyboard)

        // The test owns the Heartbeat, unless a policy asks for the real one.
        let hotMicSession = HotMicSession(
            engine: engine,
            presence: SpyPresence(),
            keyboard: policy == nil ? FakeKeyboardChannel() : app,
            clock: TestClock(),
            heartbeatClock: TestClock(),
            policy: { policy ?? .fiveMinutes }
        )
        coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            keyboardChannel: app,
            recordingEngine: engine,
            hotMicSession: hotMicSession,
            backgroundTasks: SpyBackgroundTaskRunner(),
            makeStreamingSession: { FakeRecordingStreamingSession(result: .success(transcript), finishDelay: finishDelay) }
        )
        coordinator.setupCommandListener()
        coordinator.keyboardWire.publishLaunch()
        app.writeHeartbeat(alive: true)
    }

    /// Taps START with a fresh Heartbeat: the command, or nil for a deep link.
    func sendStart() -> CommandID? {
        guard case .commandSent(let id) = keyboard.startRecording() else { return nil }
        return id
    }

    func postCommand() {
        NotificationCenter.default.post(name: .darwinCommand, object: nil)
    }

    /// Refreshes the keyboard until what it shows yields a value.
    func keyboardSees<T>(_ match: @escaping (KeyboardShown) -> T?) async throws -> T {
        var found: T?
        await waitUntil {
            found = match(self.reader.refresh())
            return found != nil
        }
        return try #require(found, "keyboard shows \(reader.shown)")
    }

    func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping @MainActor () -> Bool) async {
        let start = ContinuousClock.now
        while start.duration(to: .now) < timeout {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class MutableDate: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
