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
        guard let index = settings.modes.firstIndex(where: { $0.id == mode.id }) else { return }
        settings.modes[index].isDisabled = disabled

        // If we disabled the active mode, switch to first visible
        if disabled && settings.activeModeID == mode.id {
            if let firstVisible = settings.visibleModes.first {
                settings.activeModeID = firstVisible.id
            }
        }
    }

    private func resetToDefaults(_ mode: Mode) {
        guard let templateID = mode.templateID,
              let template = ModeTemplate.template(for: templateID),
              let index = settings.modes.firstIndex(where: { $0.id == mode.id }) else { return }
        template.resetMode(&settings.modes[index])
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
                Text(mode.name)
                    .foregroundStyle(isActive ? .green : .primary)
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
            // Template info section
            if let templateID = mode.templateID {
                Section {
                    HStack {
                        Label("Built-in mode — auto-created because the tool was detected on your system.", systemImage: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Defaults") {
                            if let template = ModeTemplate.template(for: templateID) {
                                template.resetMode(&mode)
                            }
                        }
                        .font(.caption)
                    }
                }
            }

            // Name section
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $mode.name)
                        .labelsHidden()
                        .focused($isNameFieldFocused)
                }

                Toggle("Enabled", isOn: Binding(
                    get: { !mode.isDisabled },
                    set: { mode.isDisabled = !$0 }
                ))
            }

            // Pre-processing section
            Section("Pre-processing") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Append terminator template", isOn: $mode.terminatorTemplateEnabled)

                    if mode.terminatorTemplateEnabled {
                        TextField("Terminator template", text: $mode.terminatorTemplate)
                            .labelsHidden()
                            .help("Appended after transcription if it doesn't end with punctuation. Tokens: <dot>, <space>, <newline>.")
                    }
                }
            }

            // Processing section
            Section("Processing") {
                Picker(selection: $mode.processingType) {
                    Text("None").tag(ProcessingType.none)
                    Text("Bash Script").tag(ProcessingType.bashScript)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)

                if mode.processingType == .bashScript {
                    parametersSections

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .foregroundStyle(.secondary)
                        CommandTextEditor(text: $mode.processingCommand)
                            .frame(minHeight: 80)
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

    // MARK: - Parameters

    @ViewBuilder
    private var parametersSections: some View {
        ForEach(Array(mode.parameters.enumerated()), id: \.element.id) { index, _ in
            ParameterEditorView(
                parameter: $mode.parameters[index],
                onDelete: {
                    mode.parameters.remove(at: index)
                },
                onMoveUp: index > 0 ? {
                    mode.parameters.swapAt(index, index - 1)
                } : nil,
                onMoveDown: index < mode.parameters.count - 1 ? {
                    mode.parameters.swapAt(index, index + 1)
                } : nil
            )
        }

        Button("Add Parameter") {
            mode.parameters.append(
                ModeParameter(id: UUID(), name: "", options: [
                    ModeParameterOption(id: UUID(), label: "", value: "")
                ])
            )
        }
    }
}

// MARK: - Parameter Editor

private struct ParameterEditorView: View {
    @Binding var parameter: ModeParameter
    let onDelete: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: env var label + name field + reorder/delete buttons
            HStack {
                Text("$VCDR_PARAM_\(parameter.environmentVariableSuffix)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)

                TextField("Parameter name", text: $parameter.name)
                    .textFieldStyle(.roundedBorder)
                    .fontWeight(.medium)

                Button {
                    onMoveUp?()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(onMoveUp == nil)
                .help("Move parameter up")

                Button {
                    onMoveDown?()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(onMoveDown == nil)
                .help("Move parameter down")

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Remove parameter")
            }

            // Options
            ForEach(Array(parameter.options.enumerated()), id: \.element.id) { index, _ in
                optionRow(index: index)
            }

            Button {
                parameter.options.append(
                    ModeParameterOption(id: UUID(), label: "", value: "")
                )
            } label: {
                Label("Add Option", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func optionRow(index: Int) -> some View {
        HStack(spacing: 6) {
            TextField("label", text: $parameter.options[index].label)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)

            TextField("value", text: $parameter.options[index].value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Button {
                guard index > 0 else { return }
                parameter.options.swapAt(index, index - 1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                guard index < parameter.options.count - 1 else { return }
                parameter.options.swapAt(index, index + 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(index >= parameter.options.count - 1)

            Button {
                parameter.options.remove(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.7))
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Remove option")
        }
    }
}
