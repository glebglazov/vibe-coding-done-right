import AVFoundation
import Foundation
import Testing
@testable import vcdr_ios

/// The run's origin decides Captures and delivery, a stop during Finalizing
/// is ignored, and every Finalizing holds a background task.
@MainActor
@Suite("RecordingFlowCoordinator run control", .serialized)
struct RecordingFlowCoordinatorRunControlTests {
    private struct TranscriptionFailed: Error {}

    private func makeCoordinator(
        channel: FakeKeyboardChannel = FakeKeyboardChannel(),
        backgroundTasks: SpyBackgroundTaskRunner? = nil,
        session: @escaping () -> any RecordingStreamingSession
    ) -> RecordingFlowCoordinator {
        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true
        return RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            keyboardChannel: channel,
            recordingEngine: engine,
            backgroundTasks: backgroundTasks ?? SpyBackgroundTaskRunner(),
            makeStreamingSession: session
        )
    }

    @Test("a Shortcut run never reads or clears keyboard Captures and sends the keyboard idle")
    func shortcutLeavesCapturesAlone() async {
        SessionSettings.setAIMode(.verbatim)
        defer { SessionSettings.clearAll() }
        let channel = FakeKeyboardChannel()
        channel.replaceCaptures(["kept for the keyboard"])
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
        let touchedCaptures = channel.interactions.contains {
            $0 == .readCaptures || $0 == .clearCaptures || $0 == .clearLegacySelectedText
        }
        #expect(!touchedCaptures)
        #expect(channel.readCaptures() == ["kept for the keyboard"])
        #expect(channel.interactions.last == .publish(.idle))
        #expect(coordinator.activeRunPhase == nil)
    }

    @Test("a keyboard run gets its result as a Bundled Result")
    func keyboardGetsBundledResult() async {
        SessionSettings.setAIMode(.verbatim)
        defer { SessionSettings.clearAll() }
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
        SessionSettings.setAIMode(.verbatim)
        defer { SessionSettings.clearAll() }
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
        SessionSettings.setAIMode(.verbatim)
        defer { SessionSettings.clearAll() }
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

    @Test("a stop during Arming cancels, and a second stop is ignored until the engine returns")
    func stopDuringArmingCancels() async {
        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true
        engine.startCaptureDelay = .milliseconds(200)
        let channel = FakeKeyboardChannel()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            keyboardChannel: channel,
            recordingEngine: engine,
            backgroundTasks: SpyBackgroundTaskRunner(),
            makeStreamingSession: { FakeRecordingStreamingSession() }
        )

        let start = Task { await coordinator.startRecording(origin: .shortcut) }
        await waitUntil { coordinator.activeRunPhase == .arming }

        #expect(await coordinator.stopActiveRun() == .cancelledArming)
        #expect(await coordinator.stopActiveRun() == .ignored)
        await start.value

        #expect(coordinator.activeRunPhase == nil)
        #expect(!engine.isRecording)
        #expect(channel.interactions.contains(.publish(.cancelled)))
    }
}

@MainActor
final class SpyBackgroundTaskRunner: BackgroundTaskRunner {
    private(set) var names: [String] = []
    private(set) var running = 0

    func run<T>(named name: String, _ work: () async -> T) async -> T {
        names.append(name)
        running += 1
        let result = await work()
        running -= 1
        return result
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

/// Holds `RecordingRun.stop()` inside its wait for the model, so a test can
/// act while the run is genuinely Finalizing.
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
