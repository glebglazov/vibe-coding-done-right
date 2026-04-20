import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage(AudioRecorder.preferredInputUIDKey) private var preferredInputUID = ""
    @AppStorage(
        SharedConstants.defaultAIModeKey,
        store: SharedConstants.sharedDefaults
    ) private var defaultModeRaw = AIPromptMode.dictation.rawValue
    @AppStorage(
        SharedConstants.defaultAIActiveKey,
        store: SharedConstants.sharedDefaults
    ) private var aiActiveInDictation = false
    @AppStorage(
        SharedConstants.defaultTextStyleKey,
        store: SharedConstants.sharedDefaults
    ) private var defaultStyleRaw = TextStyle.casual.rawValue
    @AppStorage(
        HistoryStoreFactory.syncEnabledDefaultsKey,
        store: SharedConstants.sharedDefaults
    ) private var syncHistoryViaICloud: Bool = true
    @State private var availableInputs: [AVAudioSessionPortDescription] = []

    var body: some View {
        NavigationStack {
            Form {
                textStyleSection
                aiProcessingSection
                syncSection
                microphoneSection
                appearanceSection
            }
            .onAppear { refreshAvailableInputs() }
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
            .onChange(of: aiActiveInDictation) { _, val in
                DefaultSettings.setAIActive(val)
            }
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
            if availableInputs.isEmpty {
                Text("No audio inputs available")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Microphone", selection: $preferredInputUID) {
                    Text("Automatic").tag("")
                    ForEach(availableInputs, id: \.uid) { input in
                        Text(input.portName).tag(input.uid)
                    }
                }
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Choose which microphone to use for recording. \"Automatic\" uses the system default.")
        }
    }

    private func refreshAvailableInputs() {
        let session = AVAudioSession.sharedInstance()

        // If the session is already active (recording in progress), just read inputs
        // without reconfiguring — changing the category mid-recording would disrupt audio.
        if session.isOtherAudioPlaying || session.category == .playAndRecord {
            availableInputs = session.availableInputs ?? []
            return
        }

        // Temporarily activate the session to query available inputs,
        // then deactivate so it doesn't interfere with other audio.
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            availableInputs = session.availableInputs ?? []
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            availableInputs = session.availableInputs ?? []
        }
    }

    // MARK: - AI Processing

    private var aiProcessingSection: some View {
        Section {
            Toggle("Enabled by Default", isOn: $aiActiveInDictation)

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
