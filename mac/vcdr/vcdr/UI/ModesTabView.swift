import SwiftUI

struct ModesTabView: View {
    @Bindable var settings: AppSettings
    @State private var selectedModeID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedModeID) {
                Section {
                    ForEach(settings.modes) { mode in
                        ModeRow(
                            mode: mode,
                            isActive: mode.id == settings.activeModeID,
                            onSetActive: { settings.activeModeID = mode.id }
                        )
                        .tag(mode.id)
                    }
                } header: {
                    HStack {
                        Text("Modes")
                        Spacer()
                        Button(action: { addMode() }) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            if let selectedID = selectedModeID,
               let index = settings.modes.firstIndex(where: { $0.id == selectedID }) {
                ModeDetailView(mode: Binding(
                    get: { settings.modes[index] },
                    set: { settings.modes[index] = $0 }
                ))
            } else {
                Text("Select a mode to edit")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func addMode() {
        let newMode = Mode(
            id: UUID(),
            name: "New Mode",
            actionType: .paste,
            bashCommand: "echo {}"
        )
        settings.modes.append(newMode)
        selectedModeID = newMode.id
    }
}

// MARK: - Mode Row

private struct ModeRow: View {
    let mode: Mode
    let isActive: Bool
    let onSetActive: () -> Void

    var body: some View {
        HStack {
            Button(action: onSetActive) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isActive ? "Active mode" : "Set as active mode")

            VStack(alignment: .leading) {
                Text(mode.name)
                Text(mode.actionType == .paste ? "Paste" : "Script")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Mode Detail View

private struct ModeDetailView: View {
    @Binding var mode: Mode

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $mode.name)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Action") {
                Picker("Type", selection: $mode.actionType) {
                    Text("Paste (Cmd+V)").tag(PostTranscriptionActionType.paste)
                    Text("Custom script").tag(PostTranscriptionActionType.bash)
                }
                .pickerStyle(.radioGroup)

                if mode.actionType == .bash {
                    TextField("Command (use {} for text)", text: $mode.bashCommand)
                        .textFieldStyle(.roundedBorder)
                        .help("Use {} as placeholder for transcribed text")
                }
            }
        }
        .formStyle(.grouped)
    }
}
