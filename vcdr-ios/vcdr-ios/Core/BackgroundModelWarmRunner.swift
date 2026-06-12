import Foundation
import OSLog

struct BackgroundModelWarmRunner: Sendable {
    private let warmer: any ModelCacheWarmer
    private let triggerStore: any BackgroundModelWarmTriggerStoring
    private let telemetry: any BackgroundModelWarmTelemetryRecording

    init(
        warmer: any ModelCacheWarmer = ParakeetBackgroundModelWarmer(),
        triggerStore: any BackgroundModelWarmTriggerStoring = UserDefaultsBackgroundModelWarmTriggerStore(),
        telemetry: any BackgroundModelWarmTelemetryRecording = LaunchTelemetryBackgroundModelWarmRecorder()
    ) {
        self.warmer = warmer
        self.triggerStore = triggerStore
        self.telemetry = telemetry
    }

    func run() async -> Bool {
        do {
            guard await shouldWarm() else {
                Logger.app.info("Background model warm completed as no-op")
                return true
            }

            try Task.checkCancellation()
            guard let outcome = try await warmer.warmParakeetCache() else {
                return true
            }
            try Task.checkCancellation()

            await telemetry.recordBackgroundWarm(outcome: outcome)
            await triggerStore.clearPendingPurgeTrigger()
            Logger.app.info("Background model warm completed successfully")
            return true
        } catch is CancellationError {
            Logger.app.warning("Background model warm cancelled before completion")
            return false
        } catch {
            Logger.app.error("Background model warm failed: \(error)")
            return false
        }
    }

    private func shouldWarm() async -> Bool {
        if await triggerStore.hasPendingPurgeTrigger() {
            return true
        }
        return await telemetry.latestRecord()?.verdict != .warm
    }
}
