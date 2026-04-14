import SwiftUI

/// List of modes with NavigationLink rows (chevrons).
/// Lives inside a NavigationStack owned by MainWindowView.
struct ModesListView: View {
    @Bindable var settings: AppSettings
    @Binding var path: NavigationPath
    @State private var showDisabledModes = false

    /// Modes to display in the list, respecting the show-disabled toggle
    private var displayedModes: [Mode] {
        if showDisabledModes {
            return settings.modes
        }
        return settings.visibleModes
    }

    var body: some View {
        List {
            ForEach(displayedModes) { mode in
                NavigationLink(value: mode.id) {
                    ModeRowView(
                        mode: mode,
                        isActive: mode.id == settings.activeModeID,
                        isHidden: !settings.visibleModes.contains(where: { $0.id == mode.id }),
                        isUnconfigured: !settings.isModeConfigured(mode),
                        switcherNumber: switcherNumber(for: mode),
                        outputDestinationName: settings.outputDestination(for: mode.defaultOutputDestinationID).name
                    )
                }
                .contextMenu {
                    Button("Set as Active") {
                        settings.activeModeID = mode.id
                    }
                    .disabled(mode.id == settings.activeModeID || mode.isDisabled)

                    Divider()

                    if mode.isDisabled {
                        Button("Enable") {
                            toggleDisabled(mode, disabled: false)
                        }
                    } else {
                        Button("Disable") {
                            toggleDisabled(mode, disabled: true)
                        }
                        .disabled(settings.visibleModes.count <= 1)
                    }

                    if mode.templateID != nil {
                        Divider()
                        Button("Reset to Defaults") {
                            resetToDefaults(mode)
                        }
                    } else {
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteMode(mode)
                        }
                        .disabled(settings.modes.count <= 1)
                    }
                }
            }
            .onDelete { indexSet in
                let modesToDelete = indexSet.map { displayedModes[$0] }
                for mode in modesToDelete where mode.templateID == nil {
                    deleteMode(mode)
                }
            }
            .onMove { source, destination in
                moveDisplayedModes(from: source, to: destination)
            }

            Section {
                Toggle("Show Disabled", isOn: $showDisabledModes)
            }
        }
        .navigationTitle("Modes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addMode) {
                    Image(systemName: "plus")
                }
                .help("Add new mode")
            }
        }
    }

    /// Returns the 1-based switcher shortcut number for a mode, or nil if not in the switcher.
    private func switcherNumber(for mode: Mode) -> Int? {
        guard let index = settings.switcherModes.firstIndex(where: { $0.id == mode.id }),
              index < ModeSwitcherPanel.maxModesInSwitcher else { return nil }
        return index + 1
    }

    private func moveDisplayedModes(from source: IndexSet, to destination: Int) {
        settings.moveDisplayedModes(displayedModes, from: source, to: destination)
    }

    private func toggleDisabled(_ mode: Mode, disabled: Bool) {
        settings.setModeDisabled(mode, disabled: disabled)
    }

    private func resetToDefaults(_ mode: Mode) {
        settings.resetModeToDefaults(mode)
    }

    private func addMode() {
        let id = settings.addMode()
        path.append(id)
    }

    private func deleteMode(_ mode: Mode) {
        settings.deleteMode(mode)
    }
}

// MARK: - Mode Row

private struct ModeRowView: View {
    let mode: Mode
    let isActive: Bool
    let isHidden: Bool
    let isUnconfigured: Bool
    /// 1-based position in the mode switcher (1-9), or nil if not in switcher
    let switcherNumber: Int?
    let outputDestinationName: String

    var body: some View {
        HStack {
            // Switcher shortcut number (matches quick mode switcher keys 1-9)
            if let number = switcherNumber {
                Text("\(number)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, alignment: .center)
            } else {
                Color.clear.frame(width: 16)
            }

            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(mode.name)
                    if isActive {
                        ActiveModeIndicator()
                    }
                }
                if isUnconfigured {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                        Text("Set \(mode.aiProvider.apiKeyVariableName) in Variables")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if mode.templateID != nil {
                Text("Built-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isHidden {
                Text("Hidden")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(isHidden || isUnconfigured ? 0.5 : 1.0)
    }

    private var subtitle: String {
        let processing: String = switch mode.processingType {
        case .none: "Direct"
        case .cloudAI: "Cloud AI · \(mode.aiProvider.displayName)"
        case .localAgent: "Local Agent · \(mode.localAgentProvider.displayName)"
        case .bashScript: "Script"
        }
        if let params = mode.defaultParameterLabels {
            return "\(processing) · \(params) → \(outputDestinationName)"
        }
        return "\(processing) → \(outputDestinationName)"
    }
}
