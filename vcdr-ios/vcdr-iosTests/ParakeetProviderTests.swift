import Foundation
import Testing
@testable import vcdr_ios

@Suite("ParakeetProvider initialization", .serialized)
struct ParakeetProviderTests {

    @Test("encoder load does not begin until core models are loaded")
    func encoderStartsAfterCoreModels() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        var loadEvents: [String] = []
        ParakeetProviderTestSupport.onModelLoadStarted = { name in
            loadEvents.append(name)
        }

        let provider = ParakeetProvider()
        try await provider.loadCoreModels()
        let coreEventCount = loadEvents.count
        #expect(coreEventCount == 3)
        #expect(loadEvents == ["Preprocessor", "Decoder", "JointDecision"])

        try await provider.finishWithEncoder()
        #expect(loadEvents.count == 4)
        #expect(loadEvents.last == "Encoder")
        let encoderIndex = loadEvents.firstIndex(of: "Encoder")
        #expect(encoderIndex == coreEventCount)

        let ready = await provider.isReady
        #expect(ready)
        let phase = await provider.initPhase
        #expect(phase == .ready)

        ParakeetProviderTestSupport.reset()
    }

    @Test("concurrent initialize callers join one in-flight init")
    func concurrentInitializeJoinsSingleInit() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.simulateCoreLoadDuration = .milliseconds(150)

        let provider = ParakeetProvider()
        async let first = provider.initialize()
        async let second = provider.initialize()
        try await first
        try await second

        #expect(ParakeetProviderTestSupport.modelLoadInvocationCount == 4)
        let ready = await provider.isReady
        #expect(ready)

        ParakeetProviderTestSupport.reset()
    }

    @Test("init phase advances downloading then compiling then ready")
    func initPhaseSequence() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.recordInitPhases = true

        let provider = ParakeetProvider()
        try await provider.initialize()

        let observed = ParakeetProviderTestSupport.recordedInitPhases
        #expect(observed.contains(.downloading))
        #expect(observed.contains(.compiling))
        #expect(observed.last == .ready)
        let finalPhase = await provider.initPhase
        #expect(finalPhase == .ready)

        ParakeetProviderTestSupport.reset()
    }

    @Test("init progress labels follow downloading compiling ready phases")
    func initProgressLabelsMatchPhases() {
        #expect(RecordingFlowCoordinator.formatInitProgress(phase: .notStarted, elapsedSeconds: 0) == "Preparing")
        #expect(RecordingFlowCoordinator.formatInitProgress(phase: .downloading, elapsedSeconds: 0) == "Downloading model")
        #expect(RecordingFlowCoordinator.formatInitProgress(phase: .compiling, elapsedSeconds: 0) == "Loading model")
        #expect(RecordingFlowCoordinator.formatInitProgress(phase: .ready, elapsedSeconds: 99) == "Ready")
        #expect(
            RecordingFlowCoordinator.formatInitProgress(phase: .compiling, elapsedSeconds: 5)
                == "Loading model · 5s"
        )
    }
}
