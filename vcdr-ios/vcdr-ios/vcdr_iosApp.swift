import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    var onOpenURLWithSource: ((URL, String?) -> Void)?

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        let sourceApp = options[.sourceApplication] as? String
        onOpenURLWithSource?(url, sourceApp)
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
