import AVFoundation
import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("RecordingFlowCoordinator run control", .serialized)
struct RecordingFlowCoordinatorRunControlTests {
    private struct TranscriptionFailed: Error {}

    private func makeCoordinator(
        channel: FakeKeyboardChannel = FakeKeyboardChannel(),
        card: SpyMicPresenceCard? = nil,
        engine: SpyWarmRecordingEngine? = nil,
        hotMicSession: HotMicSession? = nil,
        backgroundTasks: SpyBackgroundTaskRunner? = nil,
        session: @escaping () -> any RecordingStreamingSession
    ) -> RecordingFlowCoordinator {
        let engine = engine ?? SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true
        return RecordingFlowCoordinator(
            presence: card ?? SpyMicPresenceCard(),
            keyboardChannel: channel,
            recordingEngine: engine,
            hotMicSession: hotMicSession,
            backgroundTasks: backgroundTasks ?? SpyBackgroundTaskRunner(),
            makeStreamingSession: session
        )
    }

    @Test("under the Never timeout a Shortcut run releases the mic when Capturing ends, before Finalizing")
    func neverTimeoutReleasesMicAtEndOfCapturing() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let engine = SpyWarmRecordingEngine()
        let presence = SpyPresence()
        let hotMicSession = HotMicSession(
            engine: engine,
            presence: presence,
            keyboard: FakeKeyboardChannel(),
            clock: TestClock(),
            policy: { .never }
        )
        let gate = RunControlGate()
        let coordinator = makeCoordinator(engine: engine, hotMicSession: hotMicSession) {
            GatedSession(gate: gate)
        }

        await coordinator.startRecording(origin: .shortcut)
        #expect(presence.isShown)
        let stop = Task { await coordinator.stopActiveRun() }
        await waitUntil { coordinator.activeRunPhase == .finalizing }

        #expect(engine.endHotSessionCalls == 1)
        #expect(!engine.isHot)
        #expect(!presence.isShown)

        await gate.release()
        guard case .finalized(.success) = await stop.value else {
            Issue.record("Expected the run to finalize after the mic was released")
            return
        }
        #expect(engine.endHotSessionCalls == 1)
        #expect(!hotMicSession.isAlive)
    }

    @Test("a Shortcut run sends the keyboard idle")
    func shortcutSendsTheKeyboardIdle() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let channel = FakeKeyboardChannel()
        let coordinator = makeCoordinator(channel: channel) {
            FakeRecordingStreamingSession(result: .success("hello world"))
        }

        await coordinator.startRecording(origin: .shortcut)
        await settleMainActor()
        let result = await coordinator.stopActiveRun()

        guard case .finalized(.success) = result else {
            Issue.record("Expected a successful run, got \(result)")
            return
        }
        #expect(channel.interactions.last == .publish(.idle))
        #expect(coordinator.activeRunPhase == nil)
    }

    @Test("a keyboard run gets its result as a Bundled Result")
    func keyboardGetsBundledResult() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let channel = FakeKeyboardChannel()
        let coordinator = makeCoordinator(channel: channel) {
            FakeRecordingStreamingSession(result: .success("hello world"))
        }

        await coordinator.startRecording(origin: .keyboard)
        await coordinator.stopActiveRun()

        let bundled = channel.interactions.contains {
            if case .publishBundledResult(let text) = $0 { return text.localizedCaseInsensitiveContains("hello world") }
            return false
        }
        #expect(bundled)
    }

    @Test("a stop during Finalizing is ignored and the run finalizes once")
    func stopDuringFinalizingIsIgnored() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let gate = RunControlGate()
        let backgroundTasks = SpyBackgroundTaskRunner()
        let coordinator = makeCoordinator(backgroundTasks: backgroundTasks) {
            GatedSession(gate: gate)
        }

        await coordinator.startRecording(origin: .shortcut)
        let firstStop = Task { await coordinator.stopActiveRun() }
        await waitUntil { coordinator.activeRunPhase == .finalizing }

        #expect(await coordinator.stopActiveRun() == .ignored)
        #expect(RecordingToggle.command(for: coordinator.activeRunPhase) == .ignore)

        await gate.release()
        guard case .finalized(.success) = await firstStop.value else {
            Issue.record("Expected the first stop to finalize the run")
            return
        }
        #expect(backgroundTasks.names == ["Finalizing"])
    }

    @Test("a Finalizing that fails still begins and ends exactly one background task")
    func failedFinalizingEndsItsBackgroundTask() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let backgroundTasks = SpyBackgroundTaskRunner()
        let coordinator = makeCoordinator(backgroundTasks: backgroundTasks) {
            FakeRecordingStreamingSession(result: .failure(TranscriptionFailed()))
        }

        await coordinator.startRecording(origin: .app)
        let result = await coordinator.stopActiveRun()

        guard case .finalized(.processingFailure) = result else {
            Issue.record("Expected a Processing Failure, got \(result)")
            return
        }
        #expect(backgroundTasks.names == ["Finalizing"])
        #expect(backgroundTasks.running == 0)
    }

    @Test("the Finalizing background task lasts until the concluded card face has rendered")
    func finalizingTaskOutlivesTheConcludedFace() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let backgroundTasks = SpyBackgroundTaskRunner()
        let card = SpyMicPresenceCard()
        var runningWhenConcluded: Int?
        var runningWhenSettled: Int?
        card.onRunChanged = { run in
            if case .concluded? = run { runningWhenConcluded = backgroundTasks.running }
        }
        card.onSettled = { runningWhenSettled = backgroundTasks.running }
        let coordinator = makeCoordinator(card: card, backgroundTasks: backgroundTasks) {
            FakeRecordingStreamingSession(result: .success("hello world"))
        }

        await coordinator.startRecording(origin: .shortcut)
        await coordinator.stopActiveRun()

        #expect(runningWhenConcluded == 1)
        #expect(runningWhenSettled == 1)
        #expect(backgroundTasks.running == 0)
        guard case .complete(let text) = coordinator.state, text.localizedCaseInsensitiveContains("hello world") else {
            Issue.record("Expected the Done state, got \(coordinator.state)")
            return
        }
    }

    /// Race R9: the slow engine start that returns after the stop must not
    /// publish `cancelled` a second time.
    @Test("a stop during Arming cancels at once, a second stop finds no run, and cancelled is published once")
    func stopDuringArmingCancels() async {
        let engine = SpyWarmRecordingEngine()
        engine.startCaptureDelay = .milliseconds(200)
        let channel = FakeKeyboardChannel()
        let card = SpyMicPresenceCard()
        let coordinator = makeCoordinator(channel: channel, card: card, engine: engine) {
            FakeRecordingStreamingSession()
        }

        let start = Task { await coordinator.startRecording(origin: .keyboard) }
        await waitUntil { coordinator.activeRunPhase == .arming }

        #expect(await coordinator.stopActiveRun() == .cancelledArming)
        #expect(coordinator.activeRunPhase == nil)
        #expect(wireStates(channel).last == .publish(.cancelled))
        // The card shows the same face as no run.
        #expect(card.runs.last == .some(nil))
        #expect(await coordinator.stopActiveRun() == .noRun)
        #expect(await start.value == .cancelledArming)

        #expect(!engine.isRecording)
        #expect(channel.interactions.filter { $0 == .publish(.cancelled) }.count == 1)
        #expect(wireStates(channel).last == .publish(.cancelled))
    }

    /// Race R7: the stop revokes the run's capture claim, so a new start does
    /// not wait for the engine start still in flight.
    @Test("a start right after a stop during Arming captures while the first engine start is still in flight")
    func startRightAfterStopDuringArmingCaptures() async {
        let engine = SpyWarmRecordingEngine()
        engine.startCaptureDelay = .milliseconds(200)
        let channel = FakeKeyboardChannel()
        let coordinator = makeCoordinator(channel: channel, engine: engine) {
            FakeRecordingStreamingSession()
        }

        let first = Task { await coordinator.startRecording(origin: .keyboard) }
        await waitUntil { coordinator.activeRunPhase == .arming }
        let firstRun = coordinator.activeRun?.run
        #expect(await coordinator.stopActiveRun() == .cancelledArming)

        #expect(await coordinator.startRecording(origin: .keyboard) == .capturing)
        #expect(await first.value == .cancelledArming)

        guard case .capturing? = coordinator.activeRunPhase else {
            Issue.record("Expected the second run to keep Capturing, got \(String(describing: coordinator.activeRunPhase))")
            return
        }
        #expect(coordinator.activeRun?.run !== firstRun)
        #expect(engine.isRecording)
        #expect(wireStates(channel).last == .publish(.recording))
    }

    /// Race S4: the Arming Deadline (5 s, real clock) elapses while the
    /// engine start that a keyboard stop cancelled is still in flight.
    @Test("a stop during Arming publishes cancelled, and the Arming Deadline publishes nothing after it")
    func stopDuringArmingThenDeadline() async {
        let engine = SpyWarmRecordingEngine()
        engine.startCaptureDelay = .seconds(6)
        let channel = FakeKeyboardChannel()
        let hotMicSession = HotMicSession(
            engine: engine,
            presence: SpyPresence(),
            keyboard: channel,
            clock: TestClock(),
            heartbeatClock: TestClock(),
            policy: { .never }
        )
        let coordinator = makeCoordinator(channel: channel, engine: engine, hotMicSession: hotMicSession) {
            FakeRecordingStreamingSession(result: .success("hello"))
        }

        let start = Task { await coordinator.startRecording(origin: .keyboard) }
        await waitUntil { coordinator.activeRunPhase == .arming }
        await coordinator.stopFromKeyboard()
        #expect(await start.value == .cancelledArming)

        let wire = wireStates(channel)
        #expect(wire.last == .publish(.cancelled), "wire sequence: \(wire)")
        #expect(wire.filter { $0 == .publish(.cancelled) }.count == 1)
    }

    /// The Arming Deadline (5 s, real clock) fails the run while a cold
    /// `startCapture` is still warming the engine. The late engine start must
    /// not open the capture, or the mic stays on and every later Record is
    /// ignored.
    @Test("an Arming Deadline during a slow engine start leaves the mic closed, and the next Record captures")
    func armingDeadlineDuringSlowStartLeavesMicClosed() async {
        let engine = SpyWarmRecordingEngine()
        engine.startCaptureDelay = .seconds(6)
        let hotMicSession = HotMicSession(
            engine: engine,
            presence: SpyPresence(),
            keyboard: FakeKeyboardChannel(),
            clock: TestClock(),
            heartbeatClock: TestClock(),
            policy: { .never }
        )
        let coordinator = makeCoordinator(engine: engine, hotMicSession: hotMicSession) {
            FakeRecordingStreamingSession(result: .success("hello"))
        }

        let first = await coordinator.startRecording(origin: .app)
        #expect(first == .failed(RecordingRun.armingDeadlineFailureMessage))
        #expect(coordinator.activeRunPhase == nil)
        #expect(!engine.isRecording)

        engine.startCaptureDelay = .zero
        #expect(await coordinator.startRecording(origin: .app) == .capturing)
    }

    @Test("a capture lost while Capturing ends the run like a stop, and delivers what was said")
    func captureLostWhileCapturingFinalizes() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let engine = SpyWarmRecordingEngine()
        let channel = FakeKeyboardChannel()
        let coordinator = makeCoordinator(channel: channel, engine: engine) {
            FakeRecordingStreamingSession(result: .success("hello world"))
        }

        #expect(await coordinator.startRecording(origin: .keyboard) == .capturing)
        engine.loseEngine()
        await waitUntil { coordinator.activeRunPhase == nil }

        #expect(coordinator.activeRunPhase == nil)
        let bundled = channel.interactions.contains {
            if case .publishBundledResult(let text) = $0 { return text.localizedCaseInsensitiveContains("hello world") }
            return false
        }
        #expect(bundled)
        #expect(await coordinator.startRecording(origin: .keyboard) == .capturing)
    }

    @Test("a capture lost while Arming ends the run in a Processing Failure")
    func captureLostWhileArmingFails() async {
        let engine = SpyWarmRecordingEngine()
        engine.startCaptureDelay = .milliseconds(200)
        let coordinator = makeCoordinator(engine: engine) { FakeRecordingStreamingSession() }

        let start = Task { await coordinator.startRecording(origin: .app) }
        await waitUntil { coordinator.activeRunPhase == .arming }
        engine.loseEngine()
        let result = await start.value

        guard case .failed = result else {
            Issue.record("Expected a Processing Failure, got \(result)")
            return
        }
        #expect(coordinator.activeRunPhase == nil)
        #expect(!engine.isRecording)
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () -> Bool
) async {
    let start = ContinuousClock.now
    while start.duration(to: .now) < timeout {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// What the keyboard reads, without the Heartbeat.
@MainActor
private func wireStates(_ channel: FakeKeyboardChannel) -> [FakeKeyboardChannel.Interaction] {
    channel.interactions.filter {
        switch $0 {
        case .publish, .publishFailure, .publishBundledResult: true
        default: false
        }
    }
}

@MainActor
private func settleMainActor() async {
    for _ in 0..<10 { await Task.yield() }
}

private actor RunControlGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func awaitRelease() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedSession: RecordingStreamingSession {
    private let gate: RunControlGate

    init(gate: RunControlGate) {
        self.gate = gate
    }

    func start() async throws {
        await gate.awaitRelease()
    }

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {}

    func cancel() async {}

    func finish() async throws -> String {
        "hello world"
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}
