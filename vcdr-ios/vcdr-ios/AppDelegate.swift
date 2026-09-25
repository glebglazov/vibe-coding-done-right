import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    let dependencies = AppDependencies()

    /// Runs during `UIApplicationMain`, before the SwiftUI scene exists, so a
    /// cold launch from the keyboard's record URL shows Arming on the first
    /// frame instead of racing `.task` and `.onOpenURL`.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let url = launchOptions?[.url] as? URL,
           url.scheme == "vcdr-ios", url.host == "record" {
            dependencies.coordinator.prepareForDeepLinkRecording()
        }
        BackgroundModelWarmScheduler.register()
        Task {
            await BackgroundModelWarmScheduler.evaluateLaunchTriggersAndScheduleIfNeeded()
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        LogBuffer.shared.flushPendingWrites()
    }
}
