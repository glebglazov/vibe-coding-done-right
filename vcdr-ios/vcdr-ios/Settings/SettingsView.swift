import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage(AudioRecorder.preferredInputUIDKey) private var preferredInputUID = ""
    @AppStorage(AIProcessingSettings.defaultModeKey) private var defaultModeRaw = AIPromptMode.dictation.rawValue
    @AppStorage(AIProcessingSettings.enabledKey) private var aiEnabled = false
    @AppStorage(AIProcessingSettings.activeInDictationKey) private var aiActiveInDictation = false
    @AppStorage(AIProcessingSettings.providerKey) private var aiProviderRaw = AIProvider.anthropic.rawValue
    @AppStorage(AIProcessingSettings.afmFallbackEnabledKey) private var afmFallbackEnabled = false
    @AppStorage(AIProcessingSettings.afmFallbackRememberedKey) private var afmFallbackRemembered = false
    @AppStorage(StyleSettings.defaultStyleKey) private var defaultStyleRaw = TextStyle.casual.rawValue
    @State private var availableInputs: [AVAudioSessionPortDescription] = []

    var body: some View {
        NavigationStack {
            Form {
                defaultModeSection
                aiProcessingSection
                textStyleSection
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
            // Mirror settings to shared defaults for keyboard extension
            .onChange(of: aiActiveInDictation) { _, val in
                SharedConstants.sharedDefaults.set(val, forKey: SharedConstants.aiActiveKey)
            }
            .onChange(of: defaultModeRaw) { _, val in
                SharedConstants.sharedDefaults.set(val, forKey: SharedConstants.aiModeKey)
            }
            .onChange(of: defaultStyleRaw) { _, val in
                SharedConstants.sharedDefaults.set(val, forKey: SharedConstants.textStyleKey)
            }
            .onChange(of: aiEnabled) { _, _ in syncAIConfigured() }
            .onChange(of: aiProviderRaw) { _, _ in syncAIConfigured() }
        }
    }

    private func syncAIConfigured() {
        SharedConstants.sharedDefaults.set(
            AIProcessingSettings.hasAICapability,
            forKey: SharedConstants.aiConfiguredKey
        )
    }

    // MARK: - Default Mode

    private var defaultModeSection: some View {
        Section {
            Picker("Default Mode", selection: $defaultModeRaw) {
                ForEach(AIPromptMode.availableModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        } header: {
            Text("Default Mode")
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
            Picker("Default Style", selection: $defaultStyleRaw) {
                ForEach(TextStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Default Dictation Style")
        } footer: {
            Text("Default formatting for all captures.")
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
            Toggle("Enabled", isOn: $aiEnabled)

            Toggle("Active by Default", isOn: $aiActiveInDictation)

            providerPicker

            afmFallbackToggle

            NavigationLink("Configure Providers") {
                ProvidersView()
            }
        } header: {
            Text("AI Processing")
        } footer: {
            if configuredProviders.isEmpty {
                Text("No providers configured. Tap \"Configure Providers\" to add an API key.")
            } else {
                Text("Enhances transcriptions using AI.")
            }
        }
    }

    private var configuredProviders: [AIProvider] {
        AIProvider.configuredProviders
    }

    private var providerPicker: some View {
        Picker("Provider", selection: Binding(
            get: { AIProvider(rawValue: aiProviderRaw) ?? .anthropic },
            set: { newProvider in
                let oldProvider = AIProvider(rawValue: aiProviderRaw) ?? .anthropic

                // When switching TO Apple: remember fallback state, force it off
                if newProvider == .apple && oldProvider != .apple {
                    afmFallbackRemembered = afmFallbackEnabled
                    afmFallbackEnabled = false
                }
                // When switching AWAY from Apple: restore remembered fallback state
                if newProvider != .apple && oldProvider == .apple {
                    afmFallbackEnabled = afmFallbackRemembered
                }

                aiProviderRaw = newProvider.rawValue
            }
        )) {
            ForEach(configuredProviders, id: \.self) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .disabled(configuredProviders.isEmpty)
    }

    private var afmFallbackToggle: some View {
        let isDisabled = !AIProcessingSettings.isAFMAvailable
            || (AIProvider(rawValue: aiProviderRaw) ?? .anthropic) == .apple

        return Toggle("Use Apple as Fallback", isOn: $afmFallbackEnabled)
            .disabled(isDisabled)
    }
}
