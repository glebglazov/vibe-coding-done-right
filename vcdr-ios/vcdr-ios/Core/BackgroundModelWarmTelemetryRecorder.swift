import Foundation

protocol BackgroundModelWarmTelemetryRecording: Sendable {
    func latestRecord() async -> LaunchTelemetryRecord?
    func recordBackgroundWarm(outcome: LaunchLoadOutcome) async
}

struct LaunchTelemetryBackgroundModelWarmRecorder: BackgroundModelWarmTelemetryRecording {
    func latestRecord() async -> LaunchTelemetryRecord? {
        await LaunchTelemetry.latestRecord()
    }

    func recordBackgroundWarm(outcome: LaunchLoadOutcome) async {
        await LaunchTelemetry.recordBackgroundWarm(outcome: outcome)
    }
}
