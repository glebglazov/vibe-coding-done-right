import SwiftUI

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage(CompanionSettings.enabledKey) private var companionEnabled = false
    @AppStorage(CompanionSettings.hostKey) private var companionHost = ""
    @AppStorage(CompanionSettings.apiKeyKey) private var companionApiKey = ""
    @AppStorage(CompanionSettings.activeInDictationKey) private var companionActiveInDictation = false
    @State private var isEditingApiKey = false

    var body: some View {
        NavigationStack {
            ZStack {
                theme.surfaceLowest.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 32) {
                        themeSection
                        companionSection
                    }
                    .padding(24)
                }
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

    // MARK: - Companion

    private var companionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("COMPANION SERVER")

            Toggle(isOn: $companionEnabled) {
                Text("Enabled")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.onSurface)
            }
            .tint(theme.primary)

            Toggle(isOn: $companionActiveInDictation) {
                Text("Active by default in dictation")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.onSurface)
            }
            .tint(theme.primary)

            settingsField("Host", text: $companionHost, placeholder: "vcdr-server.example.com")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            maskedApiKeyField

            Text("The companion server enhances transcriptions using AI. Scan the server's QR code to configure automatically.")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    private var maskedApiKeyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
            if isEditingApiKey {
                TextField("Your API key", text: $companionApiKey)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.onSurface)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(theme.surfaceContainer)
                    .onSubmit { isEditingApiKey = false }
            } else {
                Text(maskedApiKey)
                    .font(.system(size: 14))
                    .foregroundStyle(companionApiKey.isEmpty ? theme.onSurfaceVariant : theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(theme.surfaceContainer)
                    .onTapGesture { isEditingApiKey = true }
            }
        }
    }

    private var maskedApiKey: String {
        guard companionApiKey.count > 6 else {
            return companionApiKey.isEmpty ? "Your API key" : String(repeating: "•", count: companionApiKey.count)
        }
        let prefix = companionApiKey.prefix(3)
        let suffix = companionApiKey.suffix(3)
        return "\(prefix)•••\(suffix)"
    }

    // MARK: - Components

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(3)
            .foregroundStyle(theme.onSurfaceVariant)
    }

    private func settingsField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
            TextField(placeholder, text: text)
                .font(.system(size: 14))
                .foregroundStyle(theme.onSurface)
                .padding(12)
                .background(theme.surfaceContainer)
        }
    }
}
