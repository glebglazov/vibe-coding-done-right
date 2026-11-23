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

        let provider = ParakeetProvider.inScratchModelRoot()
        try await provider.loadCoreModels(predictedVerdict: .coldSpecialize)
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

    @Test("predicted Warm starts all four model loads during core phase")
    func predictedWarmStartsAllModelsDuringCorePhase() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let gate = ModelStartGate(expectedCount: 4)
        ParakeetProviderTestSupport.onModelLoadStarted = { name in
            await gate.arrive(name)
        }

        let provider = ParakeetProvider.inScratchModelRoot()
        try await provider.loadCoreModels(predictedVerdict: .warm)

        let started = await gate.startedNames()
        #expect(Set(started) == Set(["Preprocessor", "Decoder", "JointDecision", "Encoder"]))
        #expect(ParakeetProviderTestSupport.modelLoadInvocationCount == 4)

        try await provider.finishWithEncoder()
        #expect(ParakeetProviderTestSupport.modelLoadInvocationCount == 4)
        let ready = await provider.isReady
        #expect(ready)

        ParakeetProviderTestSupport.reset()
    }

    @Test("mispredicted Warm records actual cold specialization outcome")
    func mispredictedWarmRecordsActualColdSpecializationOutcome() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.recordLaunchOutcomeForStubLoads = true
        ParakeetProviderTestSupport.stubModelsOnDiskAtInit = true
        ParakeetProviderTestSupport.stubModelLoadMilliseconds = [
            "Preprocessor": 1,
            "Decoder": 1,
            "JointDecision": 1,
            "Encoder": 4000
        ]

        let provider = ParakeetProvider.inScratchModelRoot()
        try await provider.loadCoreModels(predictedVerdict: .warm)
        try await provider.finishWithEncoder()

        let outcome = await provider.launchLoadOutcome
        #expect(outcome?.verdict == .coldSpecialize)
        #expect(outcome?.timings.encoderMs == 4000)

        ParakeetProviderTestSupport.reset()
    }

    @Test("concurrent initialize callers join one in-flight init")
    func concurrentInitializeJoinsSingleInit() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.simulateCoreLoadDuration = .milliseconds(150)

        let provider = ParakeetProvider.inScratchModelRoot()
        async let first = provider.initialize()
        async let second = provider.initialize()
        try await first
        try await second

        #expect(ParakeetProviderTestSupport.modelLoadInvocationCount == 4)
        let ready = await provider.isReady
        #expect(ready)

        ParakeetProviderTestSupport.reset()
    }

    @Test("init phase advances downloading then loading then ready")
    func initPhaseSequence() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true
        ParakeetProviderTestSupport.recordInitPhases = true

        let provider = ParakeetProvider.inScratchModelRoot()
        try await provider.initialize()

        let observed = ParakeetProviderTestSupport.recordedInitPhases
        #expect(observed.contains(.downloadingModel))
        #expect(observed.contains(.loadingModel))
        #expect(observed.last == .ready)
        let finalPhase = await provider.initPhase
        #expect(finalPhase == .ready)

        ParakeetProviderTestSupport.reset()
    }

    /// Parakeet v3's folder is the only fallback someone updating has, so it
    /// goes when Ultra has loaded and never before.
    @Test("Parakeet v3 is deleted after Ultra loads, and kept when the download or the load fails")
    func v3IsDeletedOnlyAfterUltraLoads() async throws {
        for failure in [UltraLoadFailure.download, .load, nil] {
            ParakeetProviderTestSupport.reset()
            ParakeetProviderTestSupport.bypassRealMLLoad = true
            ParakeetProviderTestSupport.failDownload = failure == .download
            ParakeetProviderTestSupport.failFinishWithEncoder = failure == .load
            let root = ParakeetProvider.scratchModelRoot()
            let v3 = root.appending(path: "parakeet-tdt-0.6b-v3", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: v3, withIntermediateDirectories: true)

            let provider = ParakeetProvider(modelRoot: root)
            let loaded = (try? await provider.initialize()) != nil

            #expect(loaded == (failure == nil))
            #expect(FileManager.default.fileExists(atPath: v3.path) == (failure != nil), "failure: \(String(describing: failure))")
        }
        ParakeetProviderTestSupport.reset()
    }
}

extension ParakeetProvider {
    /// A load deletes what Ultra replaced from its model root, and these tests
    /// run inside the real app. A provider on a fresh temporary root keeps
    /// every test load out of the app's own container.
    static func inScratchModelRoot() -> ParakeetProvider {
        ParakeetProvider(modelRoot: scratchModelRoot())
    }

    static func scratchModelRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "vcdr-parakeet-\(UUID().uuidString)/models", directoryHint: .isDirectory)
    }
}

private enum UltraLoadFailure {
    case download
    case load
}

private actor ModelStartGate {
    private let expectedCount: Int
    private var names: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func arrive(_ name: String) async {
        names.append(name)
        guard names.count < expectedCount else {
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func startedNames() -> [String] {
        names
    }
}
