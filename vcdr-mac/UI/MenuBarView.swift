import SwiftUI

struct MenuBarView: View {
    let dependencies: AppDependencies
    @Environment(\.openWindow) private var openWindow

    private static let previewLineLimit = 2
    @State private var showCopied = false
    @State private var allStyles: [Style] = []
    @State private var showStyleOverrideIndicator = false

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
                    ClipboardHelper.writeString(latest.copyableText)
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

            // Style section with current style and submenu
            StyleSection(
                currentStyle: dependencies.currentStyle,
                hasOverride: dependencies.hasStyleOverride,
                allStyles: allStyles,
                onSelectStyle: { style in
                    dependencies.setStyleOverride(style.id)
                },
                onClearOverride: {
                    dependencies.clearStyleOverride()
                }
            )
            .task {
                await loadStyles()
            }

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
        return dependencies.session.status.statusText
    }

    private var hotkeyDisplay: String {
        let binding = dependencies.settings.toggleRecordingHotkey
        guard binding.isAssigned else { return "Not set" }
        return binding.displayString
    }

    private func loadStyles() async {
        allStyles = await dependencies.styleRegistry.allStyles()
    }
}

// MARK: - Style Section

private struct StyleSection: View {
    let currentStyle: Style
    let hasOverride: Bool
    let allStyles: [Style]
    let onSelectStyle: (Style) -> Void
    let onClearOverride: () -> Void

    var body: some View {
        Menu {
            // Clear override option (only shown when override is active)
            if hasOverride {
                Button {
                    onClearOverride()
                } label: {
                    Label("Reset to App Style", systemImage: "arrow.uturn.backward")
                }

                Divider()
            }

            // List all styles with checkmark on current
            ForEach(allStyles) { style in
                Button {
                    onSelectStyle(style)
                } label: {
                    HStack {
                        Text(style.name)
                        Spacer()
                        if style.id == currentStyle.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text("Style: \(styleDisplayText)")
                    .foregroundStyle(.secondary)
                if hasOverride {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption2)
                }
            }
        }
    }

    private var styleDisplayText: String {
        if hasOverride {
            return "\(currentStyle.name) (Override)"
        }
        return currentStyle.name
    }
}

