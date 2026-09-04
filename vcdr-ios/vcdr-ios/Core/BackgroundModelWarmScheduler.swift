import BackgroundTasks
import Foundation
import OSLog

enum BackgroundModelWarmScheduler {
    static let taskIdentifier = "glebglazov.vcdr-ios.parakeet-pre-specialization"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(processingTask)
        }
    }

    static func evaluateLaunchTriggersAndScheduleIfNeeded() async {
        let store = UserDefaultsBackgroundModelWarmTriggerStore()
        await store.markVersionPurgeTriggersIfNeeded(
            appVersion: appVersion(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            rebootedSinceLastRecord: await LaunchTelemetry.rebootedSinceLastRecord()
        )
        if await store.hasPendingPurgeTrigger() {
            schedule()
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false

        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.app.info("Background model warm scheduled")
        } catch {
            Logger.app.error("Background model warm scheduling failed: \(error)")
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        let runTask = Task {
            let success = await BackgroundModelWarmRunner().run()
            schedule()
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = {
            runTask.cancel()
        }
    }

    /// The build as a purge trigger compares it: a stored key, so it keeps its
    /// own spelling rather than borrowing the version row's.
    private static func appVersion() -> String {
        "\(AppVersion.marketingVersion)-\(AppVersion.buildNumber)"
    }
}
