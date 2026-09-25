import AVFoundation
import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("RecordingFlowCoordinator model init + engine prewarm", .serialized)
struct RecordingFlowCoordinatorInitTests {

    @Test("cold download keeps the preparing hero while transcription readiness is pending")
    func coldDownloadKeepsPreparingHero() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.simulateEncoderLoadDuration = .seconds(1)

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: SpyWarmRecordingEngine(),
            transcriptionProvider: provider
        )

        let initTask = Task {
            await coordinator.initializeModel(predictedVerdict: .coldDownload)
        }

        await waitUntil { coordinator.state == .initializing }

        #expect(coordinator.state == .initializing)
        #expect(!coordinator.isModelWarming)

        await initTask.value
        ParakeetProviderTestSupport.reset()
    }

    @Test("artifacts on disk show ready hero with model warming while transcription readiness is pending")
    func artifactsOnDiskShowReadyHeroWithWarming() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.simulateEncoderLoadDuration = .seconds(1)

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: SpyWarmRecordingEngine(),
            transcriptionProvider: provider
        )

        let initTask = Task {
            await coordinator.initializeModel(predictedVerdict: .coldSpecialize)
        }

        await waitUntil { coordinator.isModelWarming }

        #expect(coordinator.state == .ready)
        #expect(coordinator.isModelWarming)

        await initTask.value
        #expect(coordinator.state == .ready)
        #expect(!coordinator.isModelWarming)

        ParakeetProviderTestSupport.reset()
    }

    @Test("record tap during model warming starts a recording run before transcription readiness")
    func recordTapDuringModelWarmingStartsRecordingRun() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.simulateEncoderLoadDuration = .seconds(1)

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: engine,
            transcriptionProvider: provider
        )

        let initTask = Task {
            await coordinator.initializeModel(predictedVerdict: .coldSpecialize)
        }

        await waitUntil { coordinator.isModelWarming }
        let readyBeforeTap = await provider.isReady
        #expect(!readyBeforeTap)

        await coordinator.startRecording(origin: .app)

        let readyAfterTap = await provider.isReady
        #expect(!readyAfterTap)
        #expect(coordinator.state == .recording)
        #expect(engine.startHotSessionCalls == 1)
        #expect(engine.isRecording)

        coordinator.reset()
        await initTask.value
        ParakeetProviderTestSupport.reset()
    }

    @Test("model warming clears and error state surfaces when transcription readiness fails")
    func modelWarmingClearsOnInitializationFailure() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.failFinishWithEncoder = true

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: SpyWarmRecordingEngine(),
            transcriptionProvider: provider
        )

        await coordinator.initializeModel(predictedVerdict: .coldSpecialize)

        #expect(!coordinator.isModelWarming)
        guard case .error(let message) = coordinator.state else {
            Issue.record("Expected error state after model init failure")
            ParakeetProviderTestSupport.reset()
            return
        }
        #expect(message.contains("Model initialization failed"))

        ParakeetProviderTestSupport.reset()
    }

    @Test("predicted-cold prewarm finishes before the encoder phase begins")
    func predictedColdPrewarmBarrierBeforeEncoder() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true
        engine.prepareEngineDelay = .milliseconds(120)

        var events: [String] = []
        engine.onPrepareEngineCompleted = {
            events.append("prewarm")
        }
        ParakeetProviderTestSupport.onFinishWithEncoderEntered = {
            events.append("encoder")
        }

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: engine,
            transcriptionProvider: provider
        )

        await coordinator.initializeModel()

        #expect(engine.prepareSessionCalls == 1)
        #expect(engine.prepareEngineCalls == 1)
        #expect(engine.startHotSessionCalls == 0)
        #expect(events == ["prewarm", "encoder"])
        let ready = await provider.isReady
        #expect(ready)

        ParakeetProviderTestSupport.reset()
    }

    @Test("predicted-warm encoder proceeds when prewarm barrier times out")
    func predictedWarmTimeoutStartsEncoderAndKeepsPrewarmRunning() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true
        engine.prepareEngineDelay = .milliseconds(150)

        let prewarmCompleted = LockedFlag()
        let encoderEntered = LockedFlag()
        engine.onPrepareEngineCompleted = {
            prewarmCompleted.set()
        }
        ParakeetProviderTestSupport.onFinishWithEncoderEntered = {
            encoderEntered.set()
        }

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: engine,
            transcriptionProvider: provider
        )

        await coordinator.initializeModel(
            predictedVerdict: .warm,
            prewarmBarrierTimeout: .milliseconds(20)
        )

        #expect(encoderEntered.value)
        #expect(!prewarmCompleted.value)

        for _ in 0..<100 {
            if prewarmCompleted.value { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(prewarmCompleted.value)
        #expect(engine.prepareSessionCalls == 1)
        #expect(engine.prepareEngineCalls == 1)

        ParakeetProviderTestSupport.reset()
    }

    @Test("predicted-warm prewarm-first ordering starts encoder after prewarm")
    func predictedWarmPrewarmFirstStartsEncoderAfterPrewarm() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true

        var events: [String] = []
        engine.onPrepareEngineCompleted = {
            events.append("prewarm")
        }
        ParakeetProviderTestSupport.onFinishWithEncoderEntered = {
            events.append("encoder")
        }

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: engine,
            transcriptionProvider: provider
        )

        await coordinator.initializeModel(
            predictedVerdict: .warm,
            prewarmBarrierTimeout: .milliseconds(100)
        )

        #expect(events == ["prewarm", "encoder"])
        #expect(engine.prepareSessionCalls == 1)
        #expect(engine.prepareEngineCalls == 1)

        ParakeetProviderTestSupport.reset()
    }

    @Test("record during encoder grind reuses pre-prepared engine")
    func recordDuringEncoderReusesPreparedEngine() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.simulateEncoderLoadDuration = .milliseconds(250)

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true

        let encoderEntered = LockedFlag()
        ParakeetProviderTestSupport.onFinishWithEncoderEntered = {
            encoderEntered.set()
        }

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: engine,
            transcriptionProvider: provider
        )

        let initTask = Task { await coordinator.initializeModel() }

        for _ in 0..<500 {
            if encoderEntered.value { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(encoderEntered.value)

        await coordinator.startRecording(origin: .app)

        #expect(engine.prepareSessionCalls == 1)
        #expect(engine.prepareEngineCalls == 1)
        #expect(engine.freshEngineBuildCalls == 0)
        #expect(engine.startEngineCalls == 1)
        #expect(engine.startHotSessionCalls == 1)

        await initTask.value
        ParakeetProviderTestSupport.reset()
    }

    @Test("init prewarm skips audio when microphone permission is unresolved")
    func initPrewarmSkipsWithoutPermission() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = false

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            recordingEngine: engine,
            transcriptionProvider: provider
        )

        await coordinator.initializeModel()

        #expect(engine.prepareSessionCalls == 0)
        #expect(engine.prepareEngineCalls == 0)

        ParakeetProviderTestSupport.reset()
    }

    @Test("model ready with finite policy does not start cold Mic Presence")
    func modelReadyWithFinitePolicyDoesNotStartColdMicPresence() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true
        let presence = SpyPresence()
        let clock = TestClock()
        let suite = "RecordingFlowCoordinatorInitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let channel = KeyboardChannel(defaults: defaults)
        let hotMicSession = HotMicSession(
            engine: engine,
            presence: presence,
            keyboard: channel,
            clock: clock,
            policy: { .fiveMinutes }
        )

        let provider = ParakeetProvider()
        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            keyboardChannel: channel,
            recordingEngine: engine,
            transcriptionProvider: provider,
            hotMicSession: hotMicSession
        )

        await coordinator.initializeModel()
        await settleMainActor()

        #expect(engine.prepareSessionCalls == 1)
        #expect(engine.prepareEngineCalls == 1)
        #expect(engine.startHotSessionCalls == 0)
        #expect(!engine.isHot)
        #expect(!channel.isAppLikelyAlive())
        #expect(presence.startCalls == 0)
        #expect(clock.sleepCount == 0)

        ParakeetProviderTestSupport.reset()
    }

    @Test("failed capture startup leaves no heartbeat or Mic Presence")
    func failedCaptureStartupLeavesNoReadinessSignals() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let engine = SpyWarmRecordingEngine()
        engine.hasMicrophonePermission = true
        engine.startSucceeds = false
        let presence = SpyPresence()
        let clock = TestClock()
        let suite = "RecordingFlowCoordinatorInitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let channel = KeyboardChannel(defaults: defaults)
        let hotMicSession = HotMicSession(
            engine: engine,
            presence: presence,
            keyboard: channel,
            clock: clock,
            policy: { .fiveMinutes }
        )

        let coordinator = RecordingFlowCoordinator(
            presence: SpyMicPresenceCard(),
            keyboardChannel: channel,
            recordingEngine: engine,
            transcriptionProvider: ParakeetProvider(),
            hotMicSession: hotMicSession
        )

        await coordinator.startRecording(origin: .app)
        await settleMainActor()

        #expect(engine.startHotSessionCalls == 1)
        #expect(engine.endHotSessionCalls == 1)
        #expect(!engine.isHot)
        #expect(!engine.isRecording)
        #expect(!channel.isAppLikelyAlive())
        #expect(presence.startCalls == 0)
        #expect(!presence.isShown)
        #expect(clock.sleepCount == 0)

        ParakeetProviderTestSupport.reset()
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

// MARK: - Test doubles

/// Models `AudioRecorder`: prewarm builds resources; capture only starts the engine.
@MainActor
final class SpyWarmRecordingEngine: RecordingEngine {
    var isHot = false
    var isRecording = false
    var hasMicrophonePermission = false
    var audioLevels: [Float] = []

    var prepareSessionCalls = 0
    var prepareEngineCalls = 0
    var startHotSessionCalls = 0
    var startEngineCalls = 0
    var freshEngineBuildCalls = 0
    var endHotSessionCalls = 0

    var prepareEngineDelay: Duration = .zero
    var startSucceeds = true
    var onPrepareEngineCompleted: (@Sendable () async -> Void)?
    /// Widens the window between `state = .arming` and Capturing so tests can
    /// land a concurrent action (e.g. Discard) mid-Arming deterministically.
    var startCaptureDelay: Duration = .zero

    private var enginePrepared = false

    func requestMicrophonePermission() async -> Bool {
        hasMicrophonePermission = true
        return true
    }

    func prepareAudioSession() async {
        prepareSessionCalls += 1
    }

    func prepareEngine() async {
        prepareEngineCalls += 1
        if prepareEngineDelay > .zero {
            try? await Task.sleep(for: prepareEngineDelay)
        }
        enginePrepared = true
        if let onPrepareEngineCompleted {
            await onPrepareEngineCompleted()
        }
    }

    func startHotSession() async -> Bool {
        startHotSessionCalls += 1
        guard startSucceeds else { return false }
        if isHot { return true }
        if enginePrepared {
            startEngineCalls += 1
        } else {
            freshEngineBuildCalls += 1
        }
        isHot = true
        return true
    }

    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool {
        _ = onBuffer
        if startCaptureDelay > .zero {
            try? await Task.sleep(for: startCaptureDelay)
        }
        if !isHot {
            guard await startHotSession() else { return false }
        }
        isRecording = true
        return true
    }

    func stopCapture() {
        isRecording = false
    }

    func endHotSession() throws {
        endHotSessionCalls += 1
        isHot = false
        isRecording = false
        enginePrepared = false
    }
}

private final class LockedFlag {
    private(set) var value = false
    func set() { value = true }
}
