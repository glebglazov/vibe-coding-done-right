import SwiftUI

/// List of modes with NavigationLink rows (chevrons).
/// Lives inside a NavigationStack owned by MainWindowView.
struct ModesListView: View {
    @Bindable var settings: AppSettings
    @Binding var path: NavigationPath
    @State private var showDisabledModes = false

    // MARK: - Constants
    private static let newModeBaseName = "New Mode"

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
                settings.modes.move(fromOffsets: source, toOffset: destination)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Toggle("Show Disabled", isOn: $showDisabledModes)
                .toggleStyle(.checkbox)
                .padding(.horizontal)
                .padding(.vertical, 8)
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
        guard let index = settings.visibleModes.firstIndex(where: { $0.id == mode.id }),
              index < 9 else { return nil }
        return index + 1
    }

    private func toggleDisabled(_ mode: Mode, disabled: Bool) {
        settings.setModeDisabled(mode, disabled: disabled)
    }

    private func resetToDefaults(_ mode: Mode) {
        guard let templateID = mode.templateID,
              let template = ModeTemplate.template(for: templateID),
              let index = settings.modes.firstIndex(where: { $0.id == mode.id }) else { return }
        template.resetMode(&settings.modes[index])
    }

    private func addMode() {
        let name = nextUniqueName(base: Self.newModeBaseName, existingNames: Set(settings.modes.map(\.name)))
        let newMode = Mode(id: UUID(), name: name)
        settings.modes.append(newMode)
        path.append(newMode.id)
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
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .shadow(color: .green.opacity(0.8), radius: 4)
                            .shadow(color: .green.opacity(0.4), radius: 8)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .opacity(isHidden ? 0.5 : 1.0)
    }

    private var subtitle: String {
        let processing = mode.processingType == .bashScript ? "Script" : "Direct"
        if let params = mode.defaultParameterLabels {
            return "\(processing) · \(params) → \(outputDestinationName)"
        }
        return "\(processing) → \(outputDestinationName)"
    }
}
