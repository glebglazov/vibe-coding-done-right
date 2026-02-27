import SwiftUI

/// List of modes with NavigationLink rows (chevrons).
/// Lives inside a NavigationStack owned by MainWindowView.
struct ModesListView: View {
    @Bindable var settings: AppSettings
    @Binding var path: NavigationPath

    // MARK: - Constants
    private static let newModeBaseName = "New Mode"

    var body: some View {
        List {
            ForEach(settings.modes) { mode in
                NavigationLink(value: mode.id) {
                    ModeRowView(
                        mode: mode,
                        isActive: mode.id == settings.activeModeID,
                        outputDestinationName: settings.outputDestination(for: mode.defaultOutputDestinationID).name
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
            name: nextUniqueModeName()
        )
        settings.modes.append(newMode)
        path.append(newMode.id)
    }

    private func nextUniqueModeName() -> String {
        let existingNames = Set(settings.modes.map(\.name))
        if !existingNames.contains(Self.newModeBaseName) {
            return Self.newModeBaseName
        }
        var counter = 1
        while existingNames.contains("\(Self.newModeBaseName) (\(counter))") {
            counter += 1
        }
        return "\(Self.newModeBaseName) (\(counter))"
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
    let outputDestinationName: String

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(mode.name)
                Text(subtitle)
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

    private var subtitle: String {
        let processing = mode.processingType == .bashScript ? "Script" : "Direct"
        return "\(processing) → \(outputDestinationName)"
    }
}

// MARK: - Mode Detail View (pushed via NavigationLink)

struct ModeDetailView: View {
    @Binding var mode: Mode
    let outputDestinations: [OutputDestination]
    @FocusState private var isNameFieldFocused: Bool

    // MARK: - Constants

    /// Delay before selecting all text — needed for the NSTextField first responder
    /// to settle after SwiftUI focus state change, otherwise selectAll is a no-op.
    private static let selectAllDelay: Duration = .milliseconds(100)

    var body: some View {
        Form {
            // Name section
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $mode.name)
                        .labelsHidden()
                        .focused($isNameFieldFocused)
                }
            }

            // Processing section
            Section("Processing") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Append terminator template", isOn: $mode.terminatorTemplateEnabled)

                    if mode.terminatorTemplateEnabled {
                        TextField("Terminator template", text: $mode.terminatorTemplate)
                            .labelsHidden()
                            .help("Appended after transcription if it doesn't end with punctuation. Tokens: <dot>, <space>, <newline>.")
                    }
                }

                Picker("Processing", selection: $mode.processingType) {
                    Text("None").tag(ProcessingType.none)
                    Text("Bash Script").tag(ProcessingType.bashScript)
                }
                .pickerStyle(.radioGroup)

                if mode.processingType == .bashScript {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .foregroundStyle(.secondary)
                        TextField("Command", text: $mode.processingCommand)
                            .labelsHidden()
                            .help("Use {} as placeholder for transcribed text. Text also available as $VCDR_TEXT.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Include system prompt in $VCDR_TEXT", isOn: $mode.systemPromptEnabled)

                        if mode.systemPromptEnabled {
                            TextEditor(text: $mode.systemPrompt)
                                .font(.body)
                                .frame(minHeight: 80)
                                .border(Color.secondary.opacity(0.3))
                                .help("This text is prepended to $VCDR_TEXT before the transcribed text")
                        }
                    }
                }
            }

            // Output section
            Section("Output") {
                Picker("Default output destination", selection: $mode.defaultOutputDestinationID) {
                    ForEach(outputDestinations) { destination in
                        Text("\(destination.symbol) \(destination.name)")
                            .tag(destination.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode.name)
        .onAppear {
            isNameFieldFocused = true
            Task { @MainActor in
                try? await Task.sleep(for: Self.selectAllDelay)
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }
}
