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
                    Logger.app.info("[LaunchProbe] .task entered main=\(Thread.isMainThread)")
                    // Cold-launch boot sequence:
                    //   0. Resolve the iCloud history container off-main.
                    //      Must come first: without this, `FileManager.url(forUbiquityContainerIdentifier:)`
                    //      used to run inside the coordinator's stored-property
                    //      initializer and froze scene construction for
                    //      seconds on first launch after install.
                    //   0b. Probe Apple Foundation Models availability off-main.
                    //       The synchronous accessor blocks for tens of seconds
                    //       on first launch after install while iOS resolves
                    //       Apple Intelligence state.
                    //   0c. Read the Transcription Model Library off disk, so
                    //       which models are installed — and which of them this
                    //       phone can install — is known before Settings asks,
                    //       then install the Default if nothing is installed.
                    //   1. Migrate pre-split legacy keys (idempotent).
                    //   2. Drop any leftover session overrides so the run
                    //      starts from the user's configured defaults.
                    //   3. Republish AI capability after the probe lands —
                    //      the keyboard extension gates its UI on the cached flag.
                    async let historyReady: Void = coordinator.bootstrapHistory()
                    async let substitutionsReady: Void = coordinator.bootstrapSubstitutions()
                    async let afmReady: Bool = AFMAvailabilityCache.shared.refresh()
                    async let libraryReady: Void = coordinator.transcriptionLibrary.refresh()
                    // Let the shell render before automatic model
                    // specialization begins. History bootstrap still overlaps
                    // model loading after that short grace period.
                    async let modelReady: Void = coordinator.initializeModelAutomatically()
                    Logger.app.info("[LaunchProbe] async-lets dispatched")
                    LegacySettingsMigrator.migrateIfNeeded()
                    Logger.app.info("[LaunchProbe] migrateIfNeeded done")
                    SessionSettings.clearAll()
                    Logger.app.info("[LaunchProbe] SessionSettings.clearAll done")
                    // The coordinator's @State init ran before migration, so
                    // its cached settings may reflect pre-migration storage.
                    // Refresh once the post-split state is authoritative.
                    coordinator.refreshSettingsFromStorage()
                    Logger.app.info("[LaunchProbe] refreshSettingsFromStorage done")
                    coordinator.cleanupStaleResults()
                    Logger.app.info("[LaunchProbe] cleanupStaleResults done")
                    coordinator.setupCommandListener()
                    Logger.app.info("[LaunchProbe] setupCommandListener done")
                    await historyReady
                    Logger.app.info("[LaunchProbe] historyReady awaited")
                    await substitutionsReady
                    Logger.app.info("[LaunchProbe] substitutionsReady awaited")
                    await libraryReady
                    Logger.app.info("[LaunchProbe] libraryReady awaited")
                    // A phone with nothing installed has no model a select
                    // could offer, so the shipped Default is fetched unasked —
                    // once, and only here (`docs/adr/0023`).
                    coordinator.transcriptionLibrary.installDefaultIfLibraryIsEmpty()
                    await modelReady
                    Logger.app.info("[LaunchProbe] initializeModel returned")
                    _ = await afmReady
                    Logger.app.info("[LaunchProbe] afmReady awaited")
                    DefaultSettings.setAIConfigured(AIProcessingSettings.hasAICapability)
                    // Fetch updated prompts in background (non-blocking)
                    Task.detached {
                        await PromptFetcher.refreshIfNeeded()
                    }
                    Logger.app.info("[LaunchProbe] .task complete")
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Logger.app.info("Scene became active — isHot=\(coordinator.isHotSessionActive), isRecording=\(coordinator.isRecording), state=\(String(describing: coordinator.state))")
                        // Re-apply idle timer state — iOS can reset it on scene transitions
                        let shouldDisable = coordinator.state == .recording
                        UIApplication.shared.isIdleTimerDisabled = shouldDisable
                        // Renew an existing Hot Mic Session without starting a
                        // cold audio engine during shell rendering. Automatic
                        // startup, when configured, happens after model-ready.
                        Task { await coordinator.handleForegroundActivation() }
                    case .background:
                        Logger.app.info("Scene entering background — isHot=\(coordinator.isHotSessionActive), isRecording=\(coordinator.isRecording)")
                        LogBuffer.shared.flushPendingWrites()
                        // Requested here rather than once suspended: the app is
                        // still executing at this transition, so a warm session
                        // can put its card back on the way out.
                        Task { await coordinator.handleBackgroundTransition() }
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
                    guard url.scheme == "vcdr-ios" else { return }
                    switch url.host {
                    case "record":
                        // Set recording state synchronously so the first rendered frame
                        // shows "LISTENING" — eliminates the flash of the previous state.
                        coordinator.prepareForDeepLinkRecording()
                        Task { await coordinator.handleRecordDeepLink() }
                    case "stop":
                        Task { await coordinator.handleStopDeepLink() }
                    case "failure":
                        // Opening the URL foregrounds this scene. Preserve the
                        // coordinator's app-owned `.error(reason)` state so
                        // RecordingView continues to show that exact reason.
                        break
                    default:
                        break
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
