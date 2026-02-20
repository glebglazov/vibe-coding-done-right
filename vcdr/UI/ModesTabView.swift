import SwiftUI

/// List of modes with NavigationLink rows (chevrons).
/// Lives inside a NavigationStack owned by MainWindowView.
struct ModesListView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        List {
            ForEach(settings.modes) { mode in
                NavigationLink(value: mode.id) {
                    ModeRowView(
                        mode: mode,
                        isActive: mode.id == settings.activeModeID
                    )
                }
                .contextMenu {
                    Button("Set as Active") {
                        settings.activeModeID = mode.id
                    }
                    .disabled(mode.id == settings.activeModeID)

                    Divider()

                    Button("Delete", role: .destructive) {
                        deleteMode(mode)
                    }
                    .disabled(settings.modes.count <= 1)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    deleteMode(settings.modes[index])
                }
            }
            .onMove { source, destination in
                settings.modes.move(fromOffsets: source, toOffset: destination)
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

    private func addMode() {
        let newMode = Mode(
            id: UUID(),
            name: "New Mode",
            actionType: .paste,
            bashCommand: "echo {}"
        )
        settings.modes.append(newMode)
    }

    private func deleteMode(_ mode: Mode) {
        guard settings.modes.count > 1 else { return }
        settings.modes.removeAll { $0.id == mode.id }
        // If we deleted the active mode, activate the first remaining
        if settings.activeModeID == mode.id {
            settings.activeModeID = settings.modes.first?.id ?? UUID()
        }
    }
}

// MARK: - Mode Row

private struct ModeRowView: View {
    let mode: Mode
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(mode.name)
                Text(mode.actionType == .paste ? "Paste" : "Script")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Mode Detail View (pushed via NavigationLink)

struct ModeDetailView: View {
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

            Section("Dictation") {
                Toggle("Append terminator", isOn: $mode.terminatorTemplateEnabled)

                if mode.terminatorTemplateEnabled {
                    TextField("Terminator Template", text: $mode.terminatorTemplate)
                        .textFieldStyle(.roundedBorder)
                        .help("Appended after transcription if it doesn't end with punctuation. Tokens: <dot>, <space>, <newline>.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode.name)
    }
}
