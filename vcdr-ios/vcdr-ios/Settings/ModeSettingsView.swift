import SwiftUI

/// One Prompt Mode's own settings: what it does with the transcript, and what
/// records it.
struct ModeSettingsView: View {
    let mode: AIPromptMode
    let coordinator: RecordingFlowCoordinator

    @AppStorage private var providerRaw: String
    @AppStorage private var afmFallback: Bool
    @AppStorage private var override: TranscriptionOverride

    init(mode: AIPromptMode, coordinator: RecordingFlowCoordinator) {
        self.mode = mode
        self.coordinator = coordinator
        _providerRaw = AppStorage(
            wrappedValue: AIProvider.anthropic.rawValue,
            AIProcessingSettings.providerKey(for: mode)
        )
        _afmFallback = AppStorage(wrappedValue: false, AIProcessingSettings.afmFallbackKey(for: mode))
        _override = AppStorage(
            wrappedValue: TranscriptionOverride.none,
            TranscriptionSettings.modeOverrideKey(for: mode)
        )
    }

    var body: some View {
        Form {
            aiProcessingSection
            ModeTranscriptionSection(override: $override, library: coordinator.transcriptionLibrary)
        }
        .navigationTitle(mode.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: providerRaw) { _, _ in
            DefaultSettings.setAIConfigured(AIProcessingSettings.hasAICapability)
        }
    }

    @ViewBuilder
    private var aiProcessingSection: some View {
        switch mode.aiProcessing {
        case .nothing(let reason):
            Section("AI Processing") {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .providerAndFallback:
            providerSection
        }
    }

    private var providerSection: some View {
        let configured = AIProvider.configuredProviders

        return Section {
            Picker("Provider", selection: Binding(
                get: { AIProvider(rawValue: providerRaw) ?? .anthropic },
                set: { providerRaw = $0.rawValue }
            )) {
                ForEach(configured, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .disabled(configured.isEmpty)

            if AIProcessingSettings.isAFMAvailable {
                Toggle("Use Apple as Fallback", isOn: $afmFallback)
                    .disabled(AIProvider(rawValue: providerRaw) == .apple)
            }
        } header: {
            Text("AI Processing")
        } footer: {
            if configured.isEmpty {
                Text("Configure a provider first in \"Providers\".")
            }
        }
    }
}
