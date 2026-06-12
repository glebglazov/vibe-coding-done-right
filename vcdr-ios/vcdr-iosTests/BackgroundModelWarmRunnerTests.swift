import Foundation
import Testing
@testable import vcdr_ios

@Suite("Background model warm runner", .serialized)
@MainActor
struct BackgroundModelWarmRunnerTests {
    @Test("Warm latest verdict with no purge trigger completes as no-op")
    func warmLatestVerdictSkipsWork() async {
        let warmer = FakeModelCacheWarmer(outcome: .warmOutcome)
        let triggerStore = FakeTriggerStore(pending: false)
        let telemetry = FakeWarmTelemetry(
            latest: .record(verdict: .warm),
            recordedOutcomes: []
        )
        let runner = BackgroundModelWarmRunner(
            warmer: warmer,
            triggerStore: triggerStore,
            telemetry: telemetry
        )

        let success = await runner.run()

        #expect(success)
        #expect(await warmer.callCount == 0)
        #expect(await telemetry.recordedOutcomes.isEmpty)
        #expect(await triggerStore.clearCount == 0)
    }

    @Test("Pending purge trigger warms, records telemetry, and clears trigger")
    func pendingTriggerWarmsAndRecords() async {
        let warmer = FakeModelCacheWarmer(outcome: .warmOutcome)
        let triggerStore = FakeTriggerStore(pending: true)
        let telemetry = FakeWarmTelemetry(
            latest: .record(verdict: .coldSpecialize),
            recordedOutcomes: []
        )
        let runner = BackgroundModelWarmRunner(
            warmer: warmer,
            triggerStore: triggerStore,
            telemetry: telemetry
        )

        let success = await runner.run()

        #expect(success)
        #expect(await warmer.callCount == 1)
        #expect(await telemetry.recordedOutcomes.count == 1)
        #expect(await triggerStore.clearCount == 1)
        #expect(await triggerStore.pending == false)
    }

    @Test("Background specialization loader touches all four Parakeet models")
    func loaderTouchesAllFourModels() async throws {
        ParakeetProviderTestSupport.reset()
        ParakeetProviderTestSupport.bypassRealMLLoad = true

        let recorder = ModelNameRecorder()
        ParakeetProviderTestSupport.onModelLoadStarted = { name in
            await recorder.append(name)
        }

        _ = try await ParakeetModelLoader.preSpecializeAllModels(
            from: URL(fileURLWithPath: "/tmp/parakeet-test"),
            qos: .utility
        )

        #expect(await recorder.names == Set(["Preprocessor", "Encoder", "Decoder", "JointDecision"]))
        #expect(ParakeetProviderTestSupport.modelLoadInvocationCount == 4)

        ParakeetProviderTestSupport.reset()
    }
}

private actor ModelNameRecorder {
    private(set) var names: Set<String> = []

    func append(_ name: String) {
        names.insert(name)
    }
}

private actor FakeModelCacheWarmer: ModelCacheWarmer {
    private let outcome: LaunchLoadOutcome?
    private(set) var callCount = 0

    init(outcome: LaunchLoadOutcome?) {
        self.outcome = outcome
    }

    func warmParakeetCache() async throws -> LaunchLoadOutcome? {
        callCount += 1
        return outcome
    }
}

private actor FakeTriggerStore: BackgroundModelWarmTriggerStoring {
    private(set) var pending: Bool
    private(set) var clearCount = 0

    init(pending: Bool) {
        self.pending = pending
    }

    func hasPendingPurgeTrigger() async -> Bool {
        pending
    }

    func markPurgeTrigger(_ reason: BackgroundModelWarmTriggerReason) async {
        pending = true
    }

    func clearPendingPurgeTrigger() async {
        pending = false
        clearCount += 1
    }
}

private actor FakeWarmTelemetry: BackgroundModelWarmTelemetryRecording {
    private let latest: LaunchTelemetryRecord?
    private(set) var recordedOutcomes: [LaunchLoadOutcome]

    init(latest: LaunchTelemetryRecord?, recordedOutcomes: [LaunchLoadOutcome]) {
        self.latest = latest
        self.recordedOutcomes = recordedOutcomes
    }

    func latestRecord() async -> LaunchTelemetryRecord? {
        latest
    }

    func recordBackgroundWarm(outcome: LaunchLoadOutcome) async {
        recordedOutcomes.append(outcome)
    }
}

private extension LaunchLoadOutcome {
    static let warmOutcome = LaunchLoadOutcome(
        verdict: .warm,
        timings: ParakeetModelLoadTimings(
            preprocessorMs: 1,
            encoderMs: 1,
            decoderMs: 1,
            jointMs: 1
        ),
        downloadMs: 0
    )
}

private extension LaunchTelemetryRecord {
    static func record(verdict: LaunchVerdict) -> LaunchTelemetryRecord {
        LaunchTelemetryRecord(
            timestamp: Date(),
            verdict: verdict,
            downloadMs: 0,
            preprocessorMs: 1,
            encoderMs: 1,
            decoderMs: 1,
            jointMs: 1,
            msToReady: nil,
            lowPowerMode: false,
            thermalState: ProcessInfo.ThermalState.nominal.rawValue,
            rebootedSinceLastLaunch: false
        )
    }
}
