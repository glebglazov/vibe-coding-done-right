import SwiftUI

@main
struct VCDRiOSApp: App {
    @State private var coordinator = RecordingFlowCoordinator()
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    coordinator.cleanupStaleResults()
                    // coordinator.setupCommandListener() — disabled: no background recording commands
                    await coordinator.initializeModel()
                    // Fetch updated prompts in background (non-blocking)
                    Task.detached {
                        await PromptFetcher.refreshIfNeeded()
                    }
                }
                .onOpenURL { url in
                    if url.scheme == "vcdr-ios", url.host == "record" {
                        // Set recording state synchronously so the first rendered frame
                        // shows "LISTENING" — eliminates the flash of the previous state.
                        coordinator.prepareForDeepLinkRecording()
                        Task { await coordinator.handleRecordDeepLink() }
                    }
                }
        }
    }
}

/// User-selectable appearance mode, stored via @AppStorage.
enum Appearance: String, CaseIterable {
    case dark
    case light
    case system

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }
}
