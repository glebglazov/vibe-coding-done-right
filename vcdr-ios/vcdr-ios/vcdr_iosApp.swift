import SwiftUI
import OSLog

@main
struct VCDRiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator: RecordingFlowCoordinator = {
        let coordinator = RecordingFlowCoordinator()
        // Flip to `.recording` before the first frame renders when the app
        // was cold-launched via the keyboard's record URL. Without this,
        // `.task` and `.onOpenURL` race on cold launch and the user sees
        // PREPARING for a beat before the view swaps to LISTENING.
        if PendingLaunchIntent.recordRequested {
            coordinator.prepareForDeepLinkRecording()
            PendingLaunchIntent.recordRequested = false
        }
        return coordinator
    }()
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    // Cold-launch boot sequence:
                    //   0. Resolve the iCloud history container off-main.
                    //      Must come first: without this, `FileManager.url(forUbiquityContainerIdentifier:)`
                    //      used to run inside the coordinator's stored-property
                    //      initializer and froze scene construction for
                    //      seconds on first launch after install.
                    //   1. Migrate pre-split legacy keys (idempotent).
                    //   2. Drop any leftover session overrides so the run
                    //      starts from the user's configured defaults.
                    //   3. Republish AI capability (keyboard gates its UI on it).
                    async let historyReady: Void = coordinator.bootstrapHistory()
                    LegacySettingsMigrator.migrateIfNeeded()
                    SessionSettings.clearAll()
                    DefaultSettings.setAIConfigured(AIProcessingSettings.hasAICapability)
                    // The coordinator's @State init ran before migration, so
                    // its cached settings may reflect pre-migration storage.
                    // Refresh once the post-split state is authoritative.
                    coordinator.refreshSettingsFromStorage()
                    coordinator.cleanupStaleResults()
                    coordinator.setupCommandListener()
                    await historyReady
                    await coordinator.initializeModel()
                    // Fetch updated prompts in background (non-blocking)
                    Task.detached {
                        await PromptFetcher.refreshIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Logger.app.info("Scene became active — isHot=\(coordinator.isHotSessionActive), isRecording=\(coordinator.isRecording), state=\(String(describing: coordinator.state))")
                        // Re-apply idle timer state — iOS can reset it on scene transitions
                        let shouldDisable = coordinator.state == .recording
                        UIApplication.shared.isIdleTimerDisabled = shouldDisable
                        // Renew the hot session (no-op if already hot) and
                        // restart the idle timer so each return to the app
                        // counts as fresh activity. `startHotSessionIfNeeded`
                        // self-heals stale `isHot` state internally, so a mic
                        // that died during background time rebuilds on foreground.
                        Task { await coordinator.startHotSessionIfNeeded() }
                    case .background:
                        Logger.app.info("Scene entering background — isHot=\(coordinator.isHotSessionActive), isRecording=\(coordinator.isRecording)")
                        // Intentionally NOT tearing down the hot session:
                        // UIBackgroundModes=audio keeps the engine alive, so
                        // the keyboard extension can drive recording via the
                        // Darwin command channel without relaunching the app.
                        // The idle timer (if finite) still ticks in background
                        // and eventually tears the session down on its own.
                        break
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
