import SwiftUI

/// List of output destinations with NavigationLink rows.
/// Lives inside a NavigationStack owned by MainWindowView.
struct OutputDestinationsListView: View {
    @Bindable var settings: AppSettings
    @Binding var path: NavigationPath

    // MARK: - Constants
    private static let newDestinationBaseName = "New Destination"

    var body: some View {
        List {
            ForEach(settings.outputDestinations) { destination in
                NavigationLink(value: OutputDestinationNavID(id: destination.id)) {
                    OutputDestinationRowView(
                        destination: destination,
                        isInUse: isDestinationInUse(destination)
                    )
                }
                .contextMenu {
                    if !destination.isBuiltIn {
                        Button("Delete", role: .destructive) {
                            deleteDestination(destination)
                        }
                        .disabled(isDestinationInUse(destination))
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let dest = settings.outputDestinations[index]
                    if !dest.isBuiltIn && !isDestinationInUse(dest) {
                        deleteDestination(dest)
                    }
                }
            }
            .onMove { source, destination in
                settings.outputDestinations.move(fromOffsets: source, toOffset: destination)
            }
        }
        .navigationTitle("Output")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addDestination) {
                    Image(systemName: "plus")
                }
                .help("Add new output destination")
            }
        }
    }

    private func addDestination() {
        let name = nextUniqueName(base: Self.newDestinationBaseName, existingNames: Set(settings.outputDestinations.map(\.name)))
        let newDest = OutputDestination.makeNewBashScript(name: name)
        settings.outputDestinations.append(newDest)
        path.append(OutputDestinationNavID(id: newDest.id))
    }

    private func isDestinationInUse(_ destination: OutputDestination) -> Bool {
        settings.isDestinationInUse(destination)
    }

    private func deleteDestination(_ destination: OutputDestination) {
        settings.deleteDestination(destination)
    }
}

// MARK: - Destination Row

private struct OutputDestinationRowView: View {
    let destination: OutputDestination
    let isInUse: Bool

    var body: some View {
        HStack {
            Text(destination.symbol)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading) {
                Text(destination.name)
                Text(destination.type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if destination.activationHotkey.isAssigned {
                Text(GlobalHotkeyManager.shortcutDisplayString(
                    keyCode: CGKeyCode(destination.activationHotkey.keyCode),
                    modifiers: CGEventFlags(rawValue: destination.activationHotkey.modifiers)
                ))
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }

            if destination.isBuiltIn {
                Text("Built-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isInUse {
                Text("In Use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Destination Detail

struct OutputDestinationDetailView: View {
    @Binding var destination: OutputDestination
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $destination.name)
                        .labelsHidden()
                        .focused($isNameFieldFocused)
                }

                if !destination.isBuiltIn {
                    // Type is not editable for built-in destinations
                    // Currently only shows "Bash Script" since that's the only user-creatable type
                    Picker("Type", selection: $destination.type) {
                        ForEach(OutputDestinationType.userCreatable, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Symbol")
                        .foregroundStyle(.secondary)
                    TextField("Symbol", text: $destination.symbol)
                        .labelsHidden()
                        .help("Displayed in the mode switcher to identify this destination")
                }

                ShortcutRecorderRow(
                    label: "Activation Hotkey",
                    keyCode: $destination.activationHotkey.keyCode,
                    modifiers: $destination.activationHotkey.modifiers
                )

                if destination.type == .bashScript {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .foregroundStyle(.secondary)
                        CommandTextEditor(text: $destination.bashCommand)
                            .frame(minHeight: 80)
                            .help("The script receives text via $VCDR_TEXT. Use {} as placeholder.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(destination.name)
        .modifier(SelectAllOnAppear(focusState: $isNameFieldFocused))
    }
}
