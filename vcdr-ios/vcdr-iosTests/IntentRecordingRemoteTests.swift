import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("IntentRecordingRemote", .serialized)
struct IntentRecordingRemoteTests {
    @MainActor
    private struct Env {
        let engine = SpyWarmRecordingEngine()
        let card = SpyMicPresenceCard()
        let coordinator: RecordingFlowCoordinator
        let remote: IntentRecordingRemote

        init(transcript: String = "hello world", startCaptureDelay: Duration = .zero, finishDelay: Duration = .zero) {
            engine.hasMicrophonePermission = true
            engine.startCaptureDelay = startCaptureDelay
            coordinator = RecordingFlowCoordinator(
                presence: card,
                keyboardChannel: FakeKeyboardChannel(),
                recordingEngine: engine,
                backgroundTasks: SpyBackgroundTaskRunner(),
                makeStreamingSession: { FakeRecordingStreamingSession(result: .success(transcript), finishDelay: finishDelay) }
            )
            remote = IntentRecordingRemote(
                boot: AppBoot(steps: AppBoot.Steps(prefix: {}, deferred: {})),
                coordinator: coordinator,
                card: card
            )
        }
    }

    private func start(_ env: Env) async -> RecordingRemoteRefusal? {
        do {
            try await env.remote.startFromShortcut()
            return nil
        } catch {
            return error
        }
    }

    private func stop(_ env: Env) async -> Result<String, RecordingRemoteRefusal> {
        do {
            return .success(try await env.remote.stopFromShortcut())
        } catch {
            return .failure(error)
        }
    }

    @Test("without microphone permission the start refuses and starts no run")
    func noMicrophonePermission() async {
        let env = Env()
        env.engine.hasMicrophonePermission = false

        #expect(await start(env) == .microphoneNotAllowed)
        #expect(env.coordinator.activeRunPhase == nil)
        #expect(env.card.runs.isEmpty)
    }

    @Test("Live Activities turned off refuse the start")
    func liveActivitiesOff() async {
        let env = Env()
        env.card.areActivitiesEnabled = false

        #expect(await start(env) == .liveActivitiesOff)
        #expect(env.coordinator.activeRunPhase == nil)
        #expect(!env.engine.isRecording)
    }

    @Test("a card ActivityKit refuses discards the run")
    func refusedCardDiscardsTheRun() async {
        let env = Env()
        env.card.showsCard = false

        #expect(await start(env) == .cardUnavailable)
        #expect(env.coordinator.activeRunPhase == nil)
        #expect(!env.engine.isRecording)
    }

    @Test("a start the engine refuses reports the failure to Shortcuts")
    func engineStartFailureIsReported() async {
        let env = Env()
        env.engine.startSucceeds = false

        guard case .runFailed(let message)? = await start(env) else {
            Issue.record("Expected a runFailed refusal")
            return
        }
        #expect(message.contains("Failed to start recording"))
        #expect(env.coordinator.activeRunPhase == nil)
        guard case .concluded(.failed, _)? = env.card.runs.last else {
            Issue.record("Expected a Failed outcome on the card, got \(String(describing: env.card.runs.last))")
            return
        }
    }

    @Test("a missing card only discards the run the check was made for")
    func missingCardDoesNotDiscardALaterRun() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let env = Env()
        env.card.showsCard = false
        env.card.whileCheckingCard = {
            await env.coordinator.stopActiveRun()
            await env.coordinator.startRecording(origin: .keyboard)
        }

        #expect(await start(env) == nil)

        guard case .capturing? = env.coordinator.activeRunPhase else {
            Issue.record("Expected the keyboard run to keep Capturing, got \(String(describing: env.coordinator.activeRunPhase))")
            return
        }
    }

    @Test("a second start keeps the run that is Capturing")
    func secondStartKeepsTheRun() async {
        let env = Env()

        #expect(await start(env) == nil)
        let run = env.coordinator.activeRun?.run
        #expect(await start(env) == nil)

        guard case .capturing? = env.coordinator.activeRunPhase else {
            Issue.record("Expected Capturing, got \(String(describing: env.coordinator.activeRunPhase))")
            return
        }
        #expect(env.coordinator.activeRun?.run === run)
    }

    @Test("a stop during Arming cancels the run and returns no text")
    func stopDuringArmingCancels() async {
        let env = Env(startCaptureDelay: .milliseconds(200))

        let first = Task { await start(env) }
        await waitUntil { env.coordinator.activeRunPhase == .arming }
        #expect(await stop(env) == .failure(.runCancelled))
        #expect(await first.value == nil)

        #expect(env.coordinator.activeRunPhase == nil)
    }

    @Test("a stop returns the final text to Shortcuts")
    func stopReturnsFinalText() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let env = Env()

        #expect(await start(env) == nil)
        guard case .success(let text) = await stop(env) else {
            Issue.record("Expected the final text")
            return
        }

        #expect(text.localizedCaseInsensitiveContains("hello world"))
        #expect(env.coordinator.activeRunPhase == nil)
    }

    @Test("a stop that hears no speech returns no text")
    func stopWithNoSpeech() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let env = Env(transcript: "")

        #expect(await start(env) == nil)
        #expect(await stop(env) == .failure(.noSpeech))
        guard case .concluded(.noSpeech, _)? = env.card.runs.last else {
            Issue.record("Expected No Speech on the card, got \(String(describing: env.card.runs.last))")
            return
        }
    }

    @Test("a stop with no run refuses and starts no run")
    func stopWithoutRun() async {
        let env = Env()

        #expect(await stop(env) == .failure(.notRecording))
        #expect(env.coordinator.activeRunPhase == nil)
        #expect(env.card.runs.isEmpty)
    }

    @Test("start then stop takes the card from Transcribing to Transcribed")
    func startThenStopConcludesTheCard() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let env = Env()

        #expect(await start(env) == nil)
        _ = await stop(env)

        let lastTwo = Array(env.card.runs.suffix(2))
        guard lastTwo.count == 2,
              case .active(.shortcut, .finalizing)? = lastTwo[0],
              case .concluded(.transcribed, _)? = lastTwo[1] else {
            Issue.record("Expected Finalizing then Transcribed, got \(lastTwo)")
            return
        }
    }

    @Test("Is Recording is true from Arming until the stop, so one Shortcut can choose Start or Stop")
    func isRecordingFollowsTheRun() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let env = Env(startCaptureDelay: .milliseconds(200))
        #expect(!env.remote.isRecording)

        let first = Task { await start(env) }
        await waitUntil { env.coordinator.activeRunPhase == .arming }
        #expect(env.remote.isRecording)
        #expect(await first.value == nil)
        #expect(env.remote.isRecording)

        _ = await stop(env)
        #expect(!env.remote.isRecording)
    }

    @Test("Is Recording is false while a stopped run is Finalizing")
    func isRecordingDuringFinalizing() async {
        SettingOverrides.setAIMode(.verbatim)
        defer { SettingOverrides.clearAll() }
        let env = Env(finishDelay: .milliseconds(200))

        #expect(await start(env) == nil)
        let stopping = Task { await stop(env) }
        await waitUntil { env.coordinator.activeRunPhase == .finalizing }
        #expect(env.coordinator.activeRunPhase == .finalizing)
        #expect(!env.remote.isRecording)
        _ = await stopping.value
    }

    @Test("the card's Stop button never starts a run")
    func stopFromCardWithoutRun() async {
        let env = Env()

        await env.remote.stopFromCard()
        await Task.yield()

        #expect(env.coordinator.activeRunPhase == nil)
        #expect(env.card.runs.isEmpty)
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
