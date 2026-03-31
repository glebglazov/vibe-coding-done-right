import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage(AudioRecorder.preferredInputUIDKey) private var preferredInputUID = ""
    @AppStorage(AIProcessingSettings.enabledKey) private var aiEnabled = false
    @AppStorage(AIProcessingSettings.activeInDictationKey) private var aiActiveInDictation = false
    @AppStorage(AIProcessingSettings.providerKey) private var aiProviderRaw = AIProvider.anthropic.rawValue
    @AppStorage(AIProcessingSettings.anthropicApiKeyKey) private var anthropicApiKey = ""
    @AppStorage(AIProcessingSettings.openaiApiKeyKey) private var openaiApiKey = ""
    @State private var isEditingAnthropicKey = false
    @State private var isEditingOpenAIKey = false
    @State private var availableInputs: [AVAudioSessionPortDescription] = []

    var body: some View {
        NavigationStack {
            ZStack {
                theme.surfaceLowest.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 32) {
                        themeSection
                        microphoneSection
                        aiProcessingSection
                    }
                    .padding(24)
                }
                .onAppear { refreshAvailableInputs() }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.primary)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: - Theme

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("APPEARANCE")

            HStack(spacing: 0) {
                ForEach(Appearance.allCases, id: \.self) { option in
                    Button {
                        appearance = option
                    } label: {
                        Text(option.label.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(appearance == option ? theme.onSurface : theme.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(appearance == option ? theme.surfaceHigh : .clear)
                    }
                }
            }
            .background(theme.surfaceContainer)
        }
    }

    // MARK: - Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("MICROPHONE")

            if availableInputs.isEmpty {
                Text("No audio inputs available")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.onSurfaceVariant)
            } else {
                VStack(spacing: 0) {
                    // "Automatic" option — uses system default
                    microphoneRow(name: "Automatic", uid: "", isSelected: preferredInputUID.isEmpty)

                    ForEach(availableInputs, id: \.uid) { input in
                        microphoneRow(name: input.portName, uid: input.uid, isSelected: preferredInputUID == input.uid)
                    }
                }
                .background(theme.surfaceContainer)
            }

            Text("Choose which microphone to use for recording. \"Automatic\" uses the system default.")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    private func microphoneRow(name: String, uid: String, isSelected: Bool) -> some View {
        Button {
            preferredInputUID = uid
        } label: {
            HStack {
                Text(name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("AI PROCESSING")

            Toggle(isOn: $aiEnabled) {
                Text("Enabled")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.onSurface)
            }
            .tint(theme.primary)

            Toggle(isOn: $aiActiveInDictation) {
                Text("Active by default")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.onSurface)
            }
            .tint(theme.primary)

            // Provider picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.onSurfaceVariant)
                HStack(spacing: 0) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Button {
                            aiProviderRaw = provider.rawValue
                        } label: {
                            Text(provider.displayName.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .tracking(2)
                                .foregroundStyle(aiProviderRaw == provider.rawValue ? theme.onSurface : theme.onSurfaceVariant)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(aiProviderRaw == provider.rawValue ? theme.surfaceHigh : .clear)
                        }
                    }
                }
                .background(theme.surfaceContainer)
            }

            // Anthropic API Key
            maskedApiKeyField(
                label: "Anthropic API Key",
                key: $anthropicApiKey,
                isEditing: $isEditingAnthropicKey
            )

            // OpenAI API Key
            maskedApiKeyField(
                label: "OpenAI API Key",
                key: $openaiApiKey,
                isEditing: $isEditingOpenAIKey
            )

            // Warning if selected provider has no key
            if aiEnabled && AIProcessingSettings.activeApiKey.isEmpty {
                let provider = AIProvider(rawValue: aiProviderRaw) ?? .anthropic
                Text("Enter your \(provider.displayName) API key to enable AI processing.")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
            }

            Text("Enhances transcriptions using AI. Enter your API key for the selected provider.")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    // MARK: - Components

    private func maskedApiKeyField(
        label: String,
        key: Binding<String>,
        isEditing: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
            if isEditing.wrappedValue {
                ApiKeyTextField(text: key, onSubmit: { isEditing.wrappedValue = false })
                    .font(.system(size: 14))
                    .foregroundStyle(theme.onSurface)
                    .padding(12)
                    .background(theme.surfaceContainer)
            } else {
                Text(maskedKey(key.wrappedValue))
                    .font(.system(size: 14))
                    .foregroundStyle(key.wrappedValue.isEmpty ? theme.onSurfaceVariant : theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(theme.surfaceContainer)
                    .onTapGesture { isEditing.wrappedValue = true }
            }
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 6 else {
            return key.isEmpty ? "Not set" : String(repeating: "\u{2022}", count: key.count)
        }
        return "\(key.prefix(3))\u{2022}\u{2022}\u{2022}\(key.suffix(3))"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(3)
            .foregroundStyle(theme.onSurfaceVariant)
    }
}

/// A TextField that auto-focuses on appear and properly supports paste.
private struct ApiKeyTextField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Your API key", text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onAppear { isFocused = true }
    }
}
