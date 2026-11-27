import SwiftUI

struct ProvidersView: View {
    var body: some View {
        List {
            providerRow(.anthropic)
            providerRow(.openai)
            providerRow(.gemini)
            providerRow(.openrouter)
            if AIProcessingSettings.isAFMAvailable {
                appleRow
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func providerRow(_ backend: CloudAIBackend) -> some View {
        let provider = AIProvider.cloud(backend)
        return NavigationLink {
            ProviderDetailView(provider: provider, apiKey: key(for: backend))
        } label: {
            HStack {
                Text(provider.displayName)
                Spacer()
                if provider.isConfigured {
                    Text("Configured")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Text("Not configured")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The Secret Store seam every other reader goes through, as an editable field.
    private func key(for backend: CloudAIBackend) -> Binding<String> {
        Binding(
            get: { AIProcessingSettings.apiKey(for: .cloud(backend)) },
            set: { newKey in
                AIProcessingSettings.setAPIKey(newKey, for: backend)
                syncAIConfigured()
            }
        )
    }

    private func syncAIConfigured() {
        DefaultSettings.setAIConfigured(AIProcessingSettings.hasAICapability)
    }

    private var appleRow: some View {
        HStack {
            Text(AIProvider.apple.displayName)
            Spacer()
            Text("Available")
                .font(.subheadline)
                .foregroundStyle(.green)
        }
    }
}

private struct ProviderDetailView: View {
    let provider: AIProvider
    @Binding var apiKey: String
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                if isEditing {
                    TextField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .focused($isFocused)
                        .onSubmit { isEditing = false }
                } else {
                    Text(apiKey.maskedAsSecret)
                        .foregroundStyle(apiKey.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isEditing = true
                            isFocused = true
                        }
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("Enter your \(provider.displayName) API key to enable this provider.")
            }

            if !apiKey.isEmpty {
                Section {
                    Button("Remove Key", role: .destructive) {
                        apiKey = ""
                        isEditing = false
                    }
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if apiKey.isEmpty {
                isEditing = true
                isFocused = true
            }
        }
    }
}
