import SwiftUI

struct ModesView: View {
    @AppStorage(AIProcessingSettings.dictationProviderKey) private var dictationProviderRaw = AIProvider.anthropic.rawValue
    @AppStorage(AIProcessingSettings.assistantProviderKey) private var assistantProviderRaw = AIProvider.anthropic.rawValue
    @AppStorage(AIProcessingSettings.dictationAfmFallbackKey) private var dictationAfmFallback = false
    @AppStorage(AIProcessingSettings.assistantAfmFallbackKey) private var assistantAfmFallback = false

    var body: some View {
        Form {
            modeSection(
                mode: .dictation,
                providerRaw: $dictationProviderRaw,
                afmFallback: $dictationAfmFallback
            )

            modeSection(
                mode: .assistant,
                providerRaw: $assistantProviderRaw,
                afmFallback: $assistantAfmFallback
            )
        }
        .navigationTitle("Modes")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: dictationProviderRaw) { _, _ in syncAIConfigured() }
        .onChange(of: assistantProviderRaw) { _, _ in syncAIConfigured() }
    }

    private func modeSection(
        mode: AIPromptMode,
        providerRaw: Binding<String>,
        afmFallback: Binding<Bool>
    ) -> some View {
        let configured = AIProvider.configuredProviders

        return Section {
            Picker("Provider", selection: Binding(
                get: { AIProvider(rawValue: providerRaw.wrappedValue) ?? .anthropic },
                set: { providerRaw.wrappedValue = $0.rawValue }
            )) {
                ForEach(configured, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .disabled(configured.isEmpty)

            if AIProcessingSettings.isAFMAvailable {
                let selectedProvider = AIProvider(rawValue: providerRaw.wrappedValue) ?? .anthropic
                Toggle("Use Apple as Fallback", isOn: afmFallback)
                    .disabled(selectedProvider == .apple)
            }
        } header: {
            Text(mode.displayName)
        } footer: {
            if configured.isEmpty {
                Text("Configure a provider first in \"Providers\".")
            }
        }
    }

    private func syncAIConfigured() {
        DefaultSettings.setAIConfigured(AIProcessingSettings.hasAICapability)
    }
}
