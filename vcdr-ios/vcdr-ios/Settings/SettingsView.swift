import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
                aiProcessingSection
                syncSection
                microphoneSection
                hotSessionSection
                keyboardSection
                appearanceSection
                #if DEBUG
                debugSection
                #endif
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

    // MARK: - Debug

    #if DEBUG
    private var debugSection: some View {
        Section {
            NavigationLink("View Logs") {
                DebugLogView()
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Visible in Xcode builds only. Reads the unified logging store for this process.")
        }
    }
    #endif

    // MARK: - AI Processing

    private var aiProcessingSection: some View {
        Section {
            Picker("Default Mode", selection: $defaultModeRaw) {
                ForEach(AIPromptMode.availableModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            NavigationLink("Configure Providers") {
                ProvidersView()
            }

            NavigationLink("Configure Modes") {
                ModesView()
            }
        } header: {
            Text("AI Processing")
        } footer: {
            if AIProvider.configuredProviders.isEmpty {
                Text("No providers configured. Tap \"Configure Providers\" to add an API key.")
            } else {
                Text("Enhances transcriptions using AI.")
            }
        }
    }
}
