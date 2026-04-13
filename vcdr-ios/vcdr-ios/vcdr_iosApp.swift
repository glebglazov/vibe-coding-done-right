import SwiftUI

@main
struct VCDRiOSApp: App {
    @State private var coordinator = RecordingFlowCoordinator()
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    SharedSettingsSync.syncAll()
                    coordinator.cleanupStaleResults()
                    coordinator.setupCommandListener()
                    await coordinator.initializeModel()
                    // Fetch updated prompts in background (non-blocking)
                    Task.detached {
                        await PromptFetcher.refreshIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        // Re-apply idle timer state — iOS can reset it on scene transitions
                        let shouldDisable = coordinator.state == .recording
                        UIApplication.shared.isIdleTimerDisabled = shouldDisable
                    case .background:
                        // Deactivate audio session so other apps can resume playback.
                        // Skip if recording is active (background audio mode keeps it alive).
                        if !coordinator.isRecording {
                            coordinator.deactivateAudioSession()
                        }
                    default:
                        break
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
