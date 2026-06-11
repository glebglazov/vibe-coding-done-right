import Testing
@testable import vcdr_ios

@Suite("Predicted Launch Verdict decision table")
struct LaunchVerdictPredictionTests {

    @Test("missing artifacts predict Cold Download regardless of history")
    func missingArtifactsPredictColdDownload() {
        #expect(
            LaunchTelemetry.predictVerdict(
                artifactsOnDisk: false,
                lastVerdict: .warm,
                rebootedSinceLastRecord: false
            ) == .coldDownload
        )
        #expect(
            LaunchTelemetry.predictVerdict(
                artifactsOnDisk: false,
                lastVerdict: nil,
                rebootedSinceLastRecord: true
            ) == .coldDownload
        )
    }

    @Test("no prior telemetry predicts Cold Specialize even with artifacts on disk")
    func noTelemetryPredictsColdSpecialize() {
        #expect(
            LaunchTelemetry.predictVerdict(
                artifactsOnDisk: true,
                lastVerdict: nil,
                rebootedSinceLastRecord: false
            ) == .coldSpecialize
        )
    }

    @Test("Warm last verdict without a reboot predicts Warm")
    func warmHistoryPredictsWarm() {
        #expect(
            LaunchTelemetry.predictVerdict(
                artifactsOnDisk: true,
                lastVerdict: .warm,
                rebootedSinceLastRecord: false
            ) == .warm
        )
    }

    @Test("cold last verdict stays a cold prediction")
    func coldHistoryStaysCold() {
        #expect(
            LaunchTelemetry.predictVerdict(
                artifactsOnDisk: true,
                lastVerdict: .coldSpecialize,
                rebootedSinceLastRecord: false
            ) == .coldSpecialize
        )
        #expect(
            LaunchTelemetry.predictVerdict(
                artifactsOnDisk: true,
                lastVerdict: .coldDownload,
                rebootedSinceLastRecord: false
            ) == .coldSpecialize
        )
    }

    @Test("reboot since the last record forces Cold Specialize over a Warm verdict")
    func rebootForcesColdSpecialize() {
        #expect(
            LaunchTelemetry.predictVerdict(
                artifactsOnDisk: true,
                lastVerdict: .warm,
                rebootedSinceLastRecord: true
            ) == .coldSpecialize
        )
    }
}
