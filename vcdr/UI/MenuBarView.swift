import SwiftUI

struct MenuBarView: View {
    let dependencies: AppDependencies
    @Environment(\.openWindow) private var openWindow

    private static let previewLineLimit = 2
    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Circle()
                    .fill(dependencies.isTranscriptionReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            if let latest = dependencies.transcriptionHistory.latestConversation {
                Divider()

                Button {
                    ClipboardHelper.writeString(latest.latestOutput)
                    CopiedFeedback.trigger { showCopied = $0 }
                } label: {
                    VStack(alignment: .leading) {
                        Text(latest.previewText)
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

            let mode = dependencies.settings.activeMode
            let dest = dependencies.settings.outputDestination(for: mode.defaultOutputDestinationID)
            Text("Mode: \(buildModeLabel(modeName: mode.name, parameterLabels: mode.defaultParameterLabels, destinationSymbol: dest.symbol))")
                .foregroundStyle(.secondary)

            Text("Hotkey: \(hotkeyDisplay)")
                .foregroundStyle(.secondary)

            Divider()

            Button("Settings...") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

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
        case .preparingToRecord: return "Starting..."
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var hotkeyDisplay: String {
        let binding = dependencies.settings.toggleRecordingHotkey
        let kc = binding.keyCode
        let mods = binding.modifiers
        guard binding.isAssigned else { return "Not set" }
        return GlobalHotkeyManager.shortcutDisplayString(
            keyCode: CGKeyCode(kc),
            modifiers: CGEventFlags(rawValue: mods)
        )
    }
}
