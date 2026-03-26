import SwiftUI
import OSLog

class AppDelegate: NSObject, UIApplicationDelegate {
    var onOpenURLWithSource: ((URL, String?) -> Void)?

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        let sourceApp = options[.sourceApplication] as? String
        Logger.app.info("[AppDelegate] application(_:open:options:) called — url=\(url.absoluteString), sourceApp=\(sourceApp ?? "nil")")
        onOpenURLWithSource?(url, sourceApp)
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Logger.app.info("[AppDelegate] didFinishLaunchingWithOptions")
        return true
    }
}

@main
struct VCDRiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var coordinator = RecordingFlowCoordinator()

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .task {
                    coordinator.cleanupStaleResults()
                    coordinator.setupBackgroundCommandListener()
                    await coordinator.initializeModel()
                }
                .onAppear {
                    appDelegate.onOpenURLWithSource = { [coordinator] url, sourceApp in
                        guard url.scheme == "vcdr-ios" else { return }
                        switch url.host {
                        case "activate":
                            Task { @MainActor in
                                await coordinator.activateAndBounceBack(sourceApp: sourceApp)
                            }
                        case "record":
                            Task { @MainActor in
                                await coordinator.handleRecordDeepLink()
                            }
                        default:
                            break
                        }
                    }
                }
        }
    }
}
