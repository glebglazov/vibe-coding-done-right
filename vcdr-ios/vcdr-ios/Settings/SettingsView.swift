import SwiftUI

struct SettingsView: View {
    let substitutionStore: any SubstitutionStore
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticsUnlock = DiagnosticsUnlock()
    @State private var showClearLogsConfirmation = false
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage(AudioRecorder.useBuiltInMicOnlyKey) private var useBuiltInMicOnly = true
    @AppStorage(
        SharedConstants.defaultAIModeKey,
        store: SharedConstants.sharedDefaults
    ) private var defaultModeRaw = AIPromptMode.verbatim.rawValue
    @AppStorage(
        SharedConstants.defaultTextStyleKey,
        store: SharedConstants.sharedDefaults
    ) private var defaultStyleRaw = TextStyle.casual.rawValue
    @AppStorage(
        HistoryStoreFactory.syncEnabledDefaultsKey,
        store: SharedConstants.sharedDefaults
    ) private var syncHistoryViaICloud: Bool = true
    @AppStorage(HotSessionTimeout.storageKey)
    private var hotSessionTimeoutSeconds: Int = HotSessionTimeout.defaultValue.rawValue
    @AppStorage(
        SharedConstants.defaultKeyboardHapticsEnabledKey,
        store: SharedConstants.sharedDefaults
    ) private var keyboardHapticsEnabled: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                textStyleSection
                substitutionsSection
                aiProcessingSection
                syncSection
                microphoneSection
                hotSessionSection
                keyboardSection
                appearanceSection
                if diagnosticsUnlock.showsSurfaces {
                    diagnosticsSection
                }
                if diagnosticsUnlock.isRevealed {
                    diagnosticsSettingsSection
                }
                versionSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            // @AppStorage above writes directly to sharedDefaults; route each
            // change through DefaultSettings so the matching session override
            // is cleared and the keyboard extension is notified.
            .onChange(of: defaultModeRaw) { _, val in
                if let mode = AIPromptMode(rawValue: val) {
                    DefaultSettings.setAIMode(mode)
                }
            }
            .onChange(of: defaultStyleRaw) { _, val in
                if let style = TextStyle(rawValue: val) {
                    DefaultSettings.setTextStyle(style)
                }
            }
            .onChange(of: hotSessionTimeoutSeconds) { _, _ in
                NotificationCenter.default.post(
                    name: HotSessionTimeout.didChangeNotification,
                    object: nil
                )
            }
            .onChange(of: keyboardHapticsEnabled) { _, val in
                DefaultSettings.setKeyboardHapticsEnabled(val)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        }
    }

    // MARK: - Text Style

    private var textStyleSection: some View {
        Section {
            ForEach(TextStyle.allCases, id: \.self) { style in
                Button {
                    defaultStyleRaw = style.rawValue
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(style.displayName)
                            Text(style.example)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if defaultStyleRaw == style.rawValue {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        } header: {
            Text("Default Dictation Style")
        }
    }

    // MARK: - Substitutions

    private var substitutionsSection: some View {
        Section {
            NavigationLink("Substitutions") {
                SubstitutionsSettings(store: substitutionStore)
            }
        } footer: {
            Text("Swap a spoken Trigger Phrase for fixed Replacement text, applied before any other processing in every mode.")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            Toggle("Sync history via iCloud", isOn: $syncHistoryViaICloud)
        } header: {
            Text("Sync")
        } footer: {
            Text("Share your transcription history with your Mac via iCloud Drive. Requires an app restart to apply.")
        }
    }

    // MARK: - Microphone

    private var microphoneSection: some View {
        Section {
            Toggle("Use built-in microphone", isOn: $useBuiltInMicOnly)
        } header: {
            Text("Microphone")
        } footer: {
            Text("Always records from the built-in mic. AirPods and other Bluetooth headsets use narrowband audio that hurts transcription accuracy, so forcing the built-in mic keeps results consistent. Turn this off to record from whatever input iOS picks — AirPods, wired headsets, USB mics — and transcription quality may vary a lot depending on the device connected.")
        }
    }

    // MARK: - Keyboard

    private var keyboardSection: some View {
        Section {
            Toggle("Haptic Feedback", isOn: $keyboardHapticsEnabled)
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Plays a tap when you press a button in the custom keyboard and when a transcription is inserted. Requires \"Allow Full Access\" to be enabled for the keyboard in iOS Settings.")
        }
    }

    // MARK: - Mic Session

    private var hotSessionSection: some View {
        Section {
            Picker("Keep Mic Warm For", selection: $hotSessionTimeoutSeconds) {
                ForEach(HotSessionTimeout.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
        } header: {
            Text("Mic Session")
        } footer: {
            Text("Keeps the microphone engine warm so the next recording starts instantly. The mic indicator stays on until this much time passes without activity, then the session ends. Choose \"Never\" to release the mic as soon as each recording stops (the indicator stays off between recordings), or \"Always\" to keep it on for the whole app lifetime.")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            NavigationLink("View Logs") {
                DebugLogView()
            }
            NavigationLink("Launch History") {
                LaunchHistoryView()
            }
            Button("Clear All Logs", role: .destructive) {
                showClearLogsConfirmation = true
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Reads the persistent log file (App Group), so entries survive app restarts.")
        }
        .confirmationDialog(
            "Clear all logs?",
            isPresented: $showClearLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                LogBuffer.shared.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all saved log entries. This cannot be undone.")
        }
    }

    // MARK: - Diagnostics Settings

    /// Sits beside the version row rather than among the diagnostics rows: a
    /// switch that hid the way back to itself would be a trap.
    private var diagnosticsSettingsSection: some View {
        Section {
            Toggle("Show Diagnostics", isOn: $diagnosticsUnlock.isShown)
            Button("Forget Diagnostics", role: .destructive) {
                diagnosticsUnlock.forget()
            }
        } header: {
            Text("Diagnostics Settings")
        } footer: {
            Text("The switch only hides the diagnostics rows — the app keeps recording its log either way. \"Forget Diagnostics\" also puts this section away until you tap the version row ten times again.")
        }
    }

    // MARK: - Version

    /// The Diagnostics Unlock lives here: the row names the running build, and
    /// ten taps on it reveal the diagnostics section.
    private var versionSection: some View {
        Section {
            Button {
                registerVersionTap()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(AppVersion.label)
                            .foregroundStyle(.secondary)
                    }
                    if let remaining = diagnosticsUnlock.tapsRemaining {
                        Text(remaining == 1 ? "1 more tap" : "\(remaining) more taps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    private func registerVersionTap() {
        guard !diagnosticsUnlock.isRevealed else { return }
        diagnosticsUnlock.registerTap()
        if diagnosticsUnlock.isRevealed {
            AppHaptics.medium()
        } else if diagnosticsUnlock.tapsRemaining != nil {
            AppHaptics.light()
        }
    }

    // MARK: - AI Processing

    private var aiProcessingSection: some View {
        Section {
            Picker("Default Mode", selection: $defaultModeRaw) {
                ForEach(AIPromptMode.availableModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            NavigationLink("Modes") {
                ModesView()
            }

            NavigationLink("Providers") {
                ProvidersView()
            }
        } header: {
            Text("AI Processing")
        } footer: {
            if AIProvider.configuredProviders.isEmpty {
                Text("No providers configured. Tap \"Providers\" to add an API key.")
            } else {
                Text("Enhances transcriptions using AI.")
            }
        }
    }
}
