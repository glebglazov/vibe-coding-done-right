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

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let marketingVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(marketingVersion)-\(buildNumber)"
    }
}
