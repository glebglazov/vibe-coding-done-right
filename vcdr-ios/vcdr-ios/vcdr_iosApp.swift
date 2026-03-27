import SwiftUI

@main
struct VCDRiOSApp: App {
    @State private var coordinator = RecordingFlowCoordinator()

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .task {
                    coordinator.cleanupStaleResults()
                    // coordinator.setupCommandListener() — disabled: no background recording commands
                    await coordinator.initializeModel()
                }
                .onOpenURL { url in
                    guard url.scheme == "vcdr-ios", url.host == "record" else { return }
                    Task { await coordinator.handleRecordDeepLink() }
                }
        }
    }
}
