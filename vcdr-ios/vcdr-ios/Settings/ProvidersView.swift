import SwiftUI

struct ProvidersView: View {
    @AppStorage(AIProcessingSettings.anthropicApiKeyKey) private var anthropicApiKey = ""
    @AppStorage(AIProcessingSettings.openaiApiKeyKey) private var openaiApiKey = ""
    @AppStorage(AIProcessingSettings.geminiApiKeyKey) private var geminiApiKey = ""

    var body: some View {
        List {
            providerRow(.anthropic, key: $anthropicApiKey)
            providerRow(.openai, key: $openaiApiKey)
            providerRow(.gemini, key: $geminiApiKey)
            if AIProcessingSettings.isAFMAvailable {
                appleRow
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: anthropicApiKey) { _, _ in syncAIConfigured() }
        .onChange(of: openaiApiKey) { _, _ in syncAIConfigured() }
        .onChange(of: geminiApiKey) { _, _ in syncAIConfigured() }
    }

    private func providerRow(_ provider: AIProvider, key: Binding<String>) -> some View {
        NavigationLink {
            ProviderDetailView(provider: provider, apiKey: key)
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
                    Text(maskedKey)
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

    private var maskedKey: String {
        guard apiKey.count > 6 else {
            return apiKey.isEmpty ? "Not set" : String(repeating: "\u{2022}", count: apiKey.count)
        }
        return "\(apiKey.prefix(3))\u{2022}\u{2022}\u{2022}\(apiKey.suffix(3))"
    }
}
