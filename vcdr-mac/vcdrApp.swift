import OSLog
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Stored reference to SwiftUI's `openWindow` action, captured from a view.
    /// This lets the delegate open SwiftUI-managed windows (including recreating
    /// them after the user closes them and the NSWindow is destroyed).
    var openMainWindow: (@MainActor () -> Void)?

    /// Delay to allow SwiftUI to finish creating Window scenes on launch
    /// before we attempt to show them via NSWindow APIs.
    private static let sceneCreationGracePeriod: Duration = .milliseconds(300)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.sceneCreationGracePeriod)
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    /// Shows the main VCDR window. Tries NSWindow lookup first (fast, no side effects),
    /// falls back to the stored SwiftUI `openWindow` action to recreate a destroyed window.
    @MainActor
    private func showMainWindow() {
        // First try to find an existing NSWindow created by SwiftUI's Window("VCDR") scene
        if let window = NSApp.windows.first(where: { $0.title == "VCDR" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Window was closed and destroyed by SwiftUI — use the stored openWindow action
        if let openMainWindow {
            openMainWindow()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            Logger.app.warning("Cannot open main window: no openWindow action captured yet")
        }
    }
}

@main
struct vcdrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var dependencies = AppDependencies()

    static let isTestHost = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(dependencies: dependencies)
        } label: {
            MenuBarLabel(
                iconName: dependencies.session.status.menuBarIcon,
                phase: dependencies.session.status.phase,
                appDelegate: appDelegate
            )
        }

        Window("VCDR", id: "main") {
            MainWindowView(dependencies: dependencies)
                .task {
                    guard !Self.isTestHost else { return }
                    await dependencies.initialize()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 650, height: 450)
    }
}

/// The menu bar icon and optional style label. Because label views are created eagerly
/// (they must render the icon), this is used to capture SwiftUI's `openWindow` action
/// and hand it to the AppDelegate so it can open windows from non-view contexts
/// (dock clicks, launch).
private struct MenuBarLabel: View {
    let iconName: String
    let phase: CaptureSession.Status.Phase
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    private var image: Image {
        switch phase {
        case .idle, .preparingToRecord:
            Image("MenuBarCassette").renderingMode(.template)
        case .recording:
            Image("MenuBarCassetteRecording").renderingMode(.original)
        case .transcribing, .executing:
            Image("MenuBarCassetteProcessing").renderingMode(.template)
        case .awaitingPreview, .error:
            Image(systemName: iconName)
        }
    }

    var body: some View {
        image
            .accessibilityLabel("VCDR")
            .onAppear {
                appDelegate.openMainWindow = { [openWindow] in
                    openWindow(id: "main")
                }
            }
    }
}
