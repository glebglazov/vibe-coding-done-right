import AVFoundation
import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("RecordingFlowCoordinator model init + engine prewarm", .serialized)
struct RecordingFlowCoordinatorInitTests {

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
            recordingEngine: engine,
            transcriptionProvider: provider
        )

        let initTask = Task { await coordinator.initializeModel() }

        for _ in 0..<500 {
            if encoderEntered.value { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(encoderEntered.value)

        await coordinator.startRecording()

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
            recordingEngine: engine,
            transcriptionProvider: provider
        )

        await coordinator.initializeModel()

        #expect(engine.prepareSessionCalls == 0)
        #expect(engine.prepareEngineCalls == 0)

        ParakeetProviderTestSupport.reset()
    }
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
