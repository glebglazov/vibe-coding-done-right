import SwiftUI
import OSLog

@main
struct VCDRiOSApp: App {
    @State private var coordinator = RecordingFlowCoordinator()

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .task {
                    coordinator.cleanupStaleResults()
                    coordinator.setupBackgroundCommandListener()
                    await coordinator.initializeModel()
                }
                .onOpenURL { url in
                    Logger.app.info("[App] onOpenURL — \(url.absoluteString)")
                    guard url.scheme == "vcdr-ios" else { return }
                    switch url.host {
                    case "activate":
                        Task { await coordinator.activateAndBounceBack() }
                    case "record":
                        Task { await coordinator.handleRecordDeepLink() }
                    default:
                        break
                    }
                }
        }
    }
}
