import SwiftUI

struct MenuBarView: View {
    let dependencies: AppDependencies
    @Environment(\.openWindow) private var openWindow

    // MARK: - Constants
    private static let previewLineLimit = 2
    private static let copiedFeedbackDuration: Duration = .seconds(1.5)

    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Circle()
                    .fill(dependencies.isTranscriptionReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            if let latest = dependencies.transcriptionHistory.latestRecord {
                Divider()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(latest.text, forType: .string)
                    showCopied = true
                    Task {
                        try? await Task.sleep(for: Self.copiedFeedbackDuration)
                        showCopied = false
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(latest.text)
                            .lineLimit(Self.previewLineLimit)
                            .truncationMode(.tail)
                        Group {
                            if showCopied {
                                Text("Copied!")
                                    .foregroundStyle(.green)
                            } else {
                                Text("Click to copy")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption2)
                        .animation(.easeInOut, value: showCopied)
                    }
                }
                .buttonStyle(.plain)
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
