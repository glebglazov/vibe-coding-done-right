import SwiftUI

// MARK: - Mode Detail View (pushed via NavigationLink)

struct ModeDetailView: View {
    @Binding var mode: Mode
    let settings: AppSettings
    let outputDestinations: [OutputDestination]
    let definedVariableNames: Set<String>
    @FocusState private var isNameFieldFocused: Bool

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
                            settings.resetModeToDefaults(mode)
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

            // Processing section
            Section("Processing") {
                Picker(selection: $mode.processingType) {
                    Text("None").tag(ProcessingType.none)
                    Text("Cloud AI").tag(ProcessingType.cloudAI)
                    Text("Bash Script").tag(ProcessingType.bashScript)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)

                if mode.processingType == .cloudAI {
                    if !settings.isModeConfigured(mode) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("Set \(mode.aiProvider.apiKeyVariableName) in Variables to use this mode.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Provider", selection: $mode.aiProvider) {
                        ForEach(AIProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    Picker("Prompt", selection: $mode.aiPromptType) {
                        ForEach(AIPromptType.allCases, id: \.self) { promptType in
                            Text(promptType.displayName).tag(promptType)
                        }
                    }

                    if mode.aiPromptType == .custom {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("System Prompt")
                                .foregroundStyle(.secondary)
                            TextEditor(text: $mode.systemPrompt)
                                .font(.body)
                                .frame(minHeight: 80)
                                .border(Color.secondary.opacity(0.3))
                        }
                    }
                }

                if mode.processingType == .bashScript {
                    if !BashScriptPreset.all.isEmpty {
                        Menu("Load Preset") {
                            ForEach(BashScriptPreset.all) { preset in
                                Button(preset.name) {
                                    preset.apply(to: &mode)
                                }
                            }
                        }
                    }

                    parametersSections

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .foregroundStyle(.secondary)
                        CommandTextEditor(text: $mode.processingCommand, definedVariableNames: definedVariableNames)
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

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Preview", isOn: $mode.showPreview)
                    Text("When enabled, shows the transcription for editing before processing. When off, the result is immediately processed and sent to the output destination.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Save result to clipboard", isOn: $mode.saveResultToClipboard)
                    Text("When enabled, the result is saved to your clipboard after the output action completes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode.name)
        .modifier(SelectAllOnAppear(focusState: $isNameFieldFocused))
    }

    // MARK: - Parameters

    @ViewBuilder
    private var parametersSections: some View {
        ForEach(Array(mode.parameters.enumerated()), id: \.element.id) { index, _ in
            ParameterEditorView(
                parameter: $mode.parameters[index],
                onDelete: {
                    mode.removeParameter(at: index)
                },
                onMoveUp: index > 0 ? {
                    mode.moveParameterUp(at: index)
                } : nil,
                onMoveDown: index < mode.parameters.count - 1 ? {
                    mode.moveParameterDown(at: index)
                } : nil
            )
        }

        Button("Add Parameter") {
            mode.addParameter()
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
                parameter.addOption()
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
                parameter.moveOptionUp(at: index)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                parameter.moveOptionDown(at: index)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(index >= parameter.options.count - 1)

            Button {
                parameter.removeOption(at: index)
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
