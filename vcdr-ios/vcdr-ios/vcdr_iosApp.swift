import SwiftUI
import OSLog
import UIKit

/// Captures the sourceApplication from URL open events, which SwiftUI's .onOpenURL doesn't provide.
/// Scene-based apps receive URLs through scene(_:openURLContexts:), not application(_:open:options:).
class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Set by the SwiftUI App on appear. Called with (url, sourceApplication).
    static var onOpenURLWithSource: ((URL, String?) -> Void)?

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let context = URLContexts.first else { return }
        let url = context.url
        let sourceApp = context.options.sourceApplication
        Logger.app.info("[SceneDelegate] scene(_:openURLContexts:) — url=\(url.absoluteString), sourceApp=\(sourceApp ?? "nil")")
        Self.onOpenURLWithSource?(url, sourceApp)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        Logger.app.info("[AppDelegate] configurationForConnecting — setting SceneDelegate")
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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
                    SceneDelegate.onOpenURLWithSource = { [coordinator] url, sourceApp in
                        Logger.app.info("[App] onOpenURLWithSource — url=\(url.absoluteString), sourceApp=\(sourceApp ?? "nil")")
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
