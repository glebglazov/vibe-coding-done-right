import SwiftUI

// MARK: - Mode Detail View (pushed via NavigationLink)

struct ModeDetailView: View {
    @Binding var mode: Mode
    let settings: AppSettings
    /// What this Mode's Transcription Override installs from, when it names a
    /// model the device does not have yet.
    let transcriptionLibrary: TranscriptionLibrary
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
                TextField("Name", text: $mode.name)
                    .focused($isNameFieldFocused)

                Toggle("Enabled", isOn: Binding(
                    get: { !mode.isDisabled },
                    set: { mode.isDisabled = !$0 }
                ))
            }

            // Processing section
            Section("Processing") {
                Picker("Type", selection: $mode.processingType) {
                    Text("None").tag(ProcessingType.none)
                    Text("Cloud AI").tag(ProcessingType.cloudAI)
                    Text("Local Agent").tag(ProcessingType.localAgent)
                    Text("Bash Script").tag(ProcessingType.bashScript)
                }

                if mode.processingType == .cloudAI {
                    if !settings.isModeConfigured(mode) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("Set the \(mode.aiProvider.displayName) API key on the Providers screen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Provider", selection: $mode.aiProvider) {
                        ForEach(settings.providerPickerOptions(selected: mode.aiProvider), id: \.self) { provider in
                            Text(providerLabel(provider)).tag(provider)
                        }
                    }
                    .onChange(of: mode.aiProvider) { _, newProvider in
                        mode.parameters = newProvider.defaultParameters
                    }

                    if !mode.parameters.isEmpty {
                        providerParametersSection
                    }

                    Picker("Prompt", selection: $mode.promptType) {
                        ForEach(PromptType.allCases, id: \.self) { promptType in
                            Text(promptType.displayName).tag(promptType)
                        }
                    }

                    if mode.promptType == .custom {
                        TextEditor(text: $mode.systemPrompt)
                            .font(.body)
                            .frame(minHeight: 80)
                    }
                }

                if mode.processingType == .localAgent {
                    Picker("Provider", selection: $mode.localAgentProvider) {
                        ForEach(LocalAgentProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: mode.localAgentProvider) { _, newProvider in
                        mode.parameters = newProvider.defaultParameters
                    }

                    localAgentParametersSection

                    Picker("Prompt", selection: $mode.promptType) {
                        ForEach(PromptType.allCases, id: \.self) { promptType in
                            Text(promptType.displayName).tag(promptType)
                        }
                    }

                    if mode.promptType == .custom {
                        TextEditor(text: $mode.systemPrompt)
                            .font(.body)
                            .frame(minHeight: 80)
                    }

                    Toggle("Pass environment variables from Variables section", isOn: $mode.localAgentPassVariables)
                        .help("When off (default), the local agent uses its own subscription credentials. When on, variables like ANTHROPIC_API_KEY are passed to the agent process, which may cause it to use your API key with token-based billing instead of the subscription.")
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

                    CommandTextEditor(text: $mode.processingCommand, definedVariableNames: definedVariableNames)
                        .help("Use {} as placeholder for transcribed text. Text also available as $VCDR_TEXT.")

                    Toggle("Include system prompt in $VCDR_TEXT", isOn: $mode.systemPromptEnabled)

                    if mode.systemPromptEnabled {
                        TextEditor(text: $mode.systemPrompt)
                            .font(.body)
                            .frame(minHeight: 80)
                            .help("This text is prepended to $VCDR_TEXT before the transcribed text")
                    }
                }
            }

            ModeTranscriptionSection(
                mode: $mode,
                settings: settings,
                library: transcriptionLibrary
            )

            // Output section
            Section("Output") {
                Picker("Default output destination", selection: $mode.defaultOutputDestinationID) {
                    ForEach(outputDestinations) { destination in
                        Text("\(destination.symbol) \(destination.name)")
                            .tag(destination.id)
                    }
                }

                Toggle("Show Preview", isOn: $mode.showPreview)
                    .help("When enabled, shows the transcription for editing before processing. When off, the result is immediately processed and sent to the output destination.")

                Toggle("Context-aware formatting", isOn: $mode.contextAware)
                    .help("When enabled, uses text around the cursor to insert separators (e.g. \". \") between dictations and adjust leading capitalization.")

                Toggle("Save result to clipboard", isOn: $mode.saveResultToClipboard)
                    .help("When enabled, the result is saved to your clipboard after the output action completes.")

                if mode.processingType != .none {
                    Toggle("Append captures to output", isOn: $mode.appendCapturesToOutput)
                        .help("When on, captures are appended after the AI response instead of being sent as input.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode.name)
        // The Transcription section shows a model's Library state, kept fresh
        // the same way the Library screen keeps itself fresh — so a download
        // named here reports its progress while the person watches.
        .task { await transcriptionLibrary.watch() }
        .modifier(SelectAllOnAppear(focusState: $isNameFieldFocused))
        .onChange(of: mode.processingType) { _, newType in
            if newType == .localAgent && mode.parameters.isEmpty {
                mode.parameters = mode.localAgentProvider.defaultParameters
            }
        }
    }

    // MARK: - Provider picker

    /// Label for a provider row: marks unconfigured providers (e.g. the Mode's
    /// pinned-but-now-unconfigured selection) so the choice never reads as valid.
    private func providerLabel(_ provider: AIProvider) -> String {
        settings.isProviderConfigured(provider)
            ? provider.displayName
            : "\(provider.displayName) — no key"
    }

    // MARK: - Local Agent Parameters (read-only)

    @ViewBuilder
    private var localAgentParametersSection: some View {
        providerParametersSection
    }

    // MARK: - Cloud AI Provider Parameters (read-only)

    @ViewBuilder
    private var providerParametersSection: some View {
        ForEach(mode.parameters) { parameter in
            VStack(alignment: .leading, spacing: 4) {
                Text(parameter.name)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    ForEach(parameter.options) { option in
                        Text(option.label)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .padding(.vertical, 2)
        }
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
