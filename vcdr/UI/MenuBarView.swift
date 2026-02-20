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

            Text("Mode: \(dependencies.settings.activeMode.name)")
                .foregroundStyle(.secondary)

            Text("Hotkey: \(hotkeyDisplay)")
                .foregroundStyle(.secondary)

            Divider()

            Button("Settings...") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit VCDR") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
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

    private var hotkeyDisplay: String {
        let binding = dependencies.settings.pushToTalkHotkey
        let kc = binding.keyCode
        let mods = binding.modifiers
        guard binding.isAssigned else { return "Not set" }
        return GlobalHotkeyManager.shortcutDisplayString(
            keyCode: CGKeyCode(kc),
            modifiers: CGEventFlags(rawValue: mods)
        )
    }
}
