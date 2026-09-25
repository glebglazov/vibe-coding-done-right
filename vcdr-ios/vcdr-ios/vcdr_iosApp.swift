import SwiftUI
import OSLog

@main
struct VCDRiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.scenePhase) private var scenePhase

    private var coordinator: RecordingFlowCoordinator { appDelegate.dependencies.coordinator }

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    appDelegate.dependencies.boot.launch()
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
                        coordinator.handleBackgroundTransition()
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
