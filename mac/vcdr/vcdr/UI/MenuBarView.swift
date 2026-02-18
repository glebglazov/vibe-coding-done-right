import SwiftUI

struct MenuBarView: View {
    let dependencies: AppDependencies
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Circle()
                    .fill(dependencies.isTranscriptionReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            Divider()

            Text("Action: \(actionLabel)")
                .foregroundStyle(.secondary)

            Text("Hotkey: \(hotkeyDisplay)")
                .foregroundStyle(.secondary)

            Divider()

            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit VCDR") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private var statusText: String {
        if !dependencies.isTranscriptionReady {
            return dependencies.initializationStatus
        }
        switch dependencies.coordinator.state {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .executing: return "Executing action..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var actionLabel: String {
        switch dependencies.settings.actionType {
        case .paste: "Paste"
        case .bash: "Bash"
        }
    }

    private var hotkeyDisplay: String {
        let mgr = GlobalHotkeyManager()
        return mgr.shortcutDisplayString(
            keyCode: CGKeyCode(dependencies.settings.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: dependencies.settings.hotkeyModifiers)
        )
    }
}
