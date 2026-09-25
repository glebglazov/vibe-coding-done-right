import AVFoundation
import Foundation
import Testing
@testable import vcdr_ios

/// Discard (ADR-0003): ending a Recording Run without producing text. Scoped
/// to Arming and Capturing; a Discard arriving during Finalizing is ignored.
@MainActor
@Suite("RecordingFlowCoordinator Discard", .serialized)
struct RecordingFlowCoordinatorDiscardTests {

    @Test("discard during Arming cancels via the existing mid-Arming stop path")
    func discardDuringArmingCancelsExistingPath() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true
        // Widen the Arming window so `discardRecording()` reliably lands
        // before `startCapture` returns and the run reaches Capturing.
        engine.startCaptureDelay = .milliseconds(200)

        let suite = "RecordingFlowCoordinatorDiscardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let channel = KeyboardChannel(defaults: defaults)
        channel.replaceCaptures(["mid-arming capture"])

        let coordinator = RecordingFlowCoordinator(
            keyboardChannel: channel,
            recordingEngine: engine,
            transcriptionProvider: ParakeetProvider()
        )

        let startTask = Task { await coordinator.startRecording(origin: .app) }
        await waitUntil { coordinator.state == .arming }
        // Let the fire-and-forget captures-read Task inside `startRecording`
        // land before discarding, so clearing is asserted against a non-empty
        // starting point rather than trivially passing on an unset array.
        await settleMainActor()
        #expect(coordinator.capturedTexts == ["mid-arming capture"])

        await coordinator.discardRecording()
        await startTask.value

        #expect(coordinator.state == .cancelled)
        try? await Task.sleep(for: .seconds(HoldToDiscardController.cancelledFlashDuration + 0.05))
        #expect(coordinator.state == .idle)
        #expect(!engine.isRecording)
        #expect(coordinator.capturedTexts.isEmpty)
        #expect(channel.readCaptures().isEmpty)

        ParakeetProviderTestSupport.reset()
    }

    @Test("discard during Capturing cancels the run and keeps the Hot Mic Session warm")
    func discardDuringCapturingCancelsRun() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true

        let suite = "RecordingFlowCoordinatorDiscardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let channel = KeyboardChannel(defaults: defaults)
        channel.replaceCaptures(["captured while recording"])

        let presence = SpyPresence()
        let clock = TestClock()
        let hotMicSession = HotMicSession(
            engine: engine,
            presence: presence,
            keyboard: channel,
            clock: clock,
            policy: { .always }
        )

        let coordinator = RecordingFlowCoordinator(
            keyboardChannel: channel,
            recordingEngine: engine,
            transcriptionProvider: ParakeetProvider(),
            hotMicSession: hotMicSession
        )

        await coordinator.startRecording(origin: .app)
        await settleMainActor()
        #expect(coordinator.state == .recording)
        #expect(coordinator.capturedTexts == ["captured while recording"])

        await coordinator.discardRecording()

        #expect(coordinator.state == .cancelled)
        try? await Task.sleep(for: .seconds(HoldToDiscardController.cancelledFlashDuration + 0.05))
        #expect(coordinator.state == .ready)
        #expect(engine.isHot)
        #expect(!engine.isRecording)
        #expect(coordinator.capturedTexts.isEmpty)
        #expect(channel.readCaptures().isEmpty)
        #expect(channel.readState() == .idle)

        ParakeetProviderTestSupport.reset()
    }

    @Test("discard during Finalizing is ignored and the run completes normally")
    func discardDuringFinalizingIsIgnored() async throws {
        // `currentSettings()` resyncs from the real app-group defaults right
        // before the finalize path reads it (cross-process staleness guard),
        // which would clobber a property assignment on the coordinator.
        // Write Verbatim into shared defaults itself so the run's finalize
        // path stays local/deterministic and never reaches a real AI
        // provider; restore on exit since this suite is process-global.
        SessionSettings.setAIMode(.verbatim)
        defer { SessionSettings.clearAll() }

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true

        let suite = "RecordingFlowCoordinatorDiscardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let channel = KeyboardChannel(defaults: defaults)

        let gate = FinalizingGate()
        let coordinator = RecordingFlowCoordinator(
            keyboardChannel: channel,
            recordingEngine: engine,
            transcriptionProvider: ParakeetProvider(),
            makeStreamingSession: { GatedStreamingSession(gate: gate, finishText: "hello world") }
        )

        await coordinator.startRecording(origin: .app)
        #expect(coordinator.state == .recording)

        let stopTask = Task { await coordinator.stopActiveRun() }
        await waitUntil { coordinator.state == .transcribing }

        await coordinator.discardRecording()
        #expect(coordinator.state == .transcribing)

        await gate.release()
        await stopTask.value

        guard case .complete(let text) = coordinator.state else {
            Issue.record("Expected the run to complete normally despite the Discard; got \(coordinator.state)")
            return
        }
        #expect(text.contains("hello world"))
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

@MainActor
private func settleMainActor() async {
    for _ in 0..<10 { await Task.yield() }
}

// MARK: - Finalizing gate

/// Lets a test hold `RecordingRun.stop()` suspended inside `setupTask` (the
/// wrapped `streaming.start(using:)`) so it can exercise Discard while the
/// run is genuinely in Finalizing, then release it to observe the run
/// complete on its own.
private actor FinalizingGate {
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

/// Never prepares a model — Finalizing-phase tests need no real model load,
/// only control over when `RecordingRun.stop()`'s wait on `setupTask` resolves.
private actor GatedStreamingSession: RecordingStreamingSession {
    private let gate: FinalizingGate
    private let finishText: String

    init(gate: FinalizingGate, finishText: String) {
        self.gate = gate
        self.finishText = finishText
    }

    func start() async throws {
        await gate.awaitRelease()
    }

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {}

    func cancel() async {}

    func finish() async throws -> String {
        finishText
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
