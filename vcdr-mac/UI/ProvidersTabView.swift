import SwiftUI

/// Lists the cloud AI Providers with their configured status. Each row pushes a
/// `ProviderDetailView` for editing the key. The AI Provider owns its API Key as
/// the single source of truth — see `docs/adr/0001-ai-provider-key-source-of-truth.md`.
struct ProvidersListView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        List {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                NavigationLink(value: provider) {
                    ProviderRowView(
                        provider: provider,
                        isConfigured: settings.isProviderConfigured(provider)
                    )
                }
            }
        }
        .navigationTitle("Providers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Providers are a fixed set with nothing to add, but every other
                // settings list contributes a toolbar item. Reserving the toolbar
                // region here makes the window's unified title bar extend over the
                // sidebar so it wraps the traffic-light buttons, matching the rest.
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }
}

// MARK: - Provider Row

private struct ProviderRowView: View {
    let provider: AIProvider
    let isConfigured: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                if isConfigured {
                    Text("Configured")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Not configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Provider Detail

/// Edits a single AI Provider's API key. Mirrors the iOS `ProviderDetailView`:
/// the key is shown masked and becomes an editable field on tap.
struct ProviderDetailView: View {
    let provider: AIProvider
    @Binding var apiKey: String
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                if isEditing {
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($isFocused)
                        .onSubmit { isEditing = false }
                } else {
                    Text(maskedKey)
                        .font(.system(.body, design: .monospaced))
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
        .formStyle(.grouped)
        .navigationTitle(provider.displayName)
        .onAppear {
            if apiKey.isEmpty {
                isEditing = true
                isFocused = true
            }
        }
    }

    /// Masks all but the first and last three characters of the key.
    private var maskedKey: String {
        guard apiKey.count > 6 else {
            return apiKey.isEmpty ? "Not set" : String(repeating: "\u{2022}", count: apiKey.count)
        }
        return "\(apiKey.prefix(3))\u{2022}\u{2022}\u{2022}\(apiKey.suffix(3))"
    }
}
