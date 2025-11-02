//
//  SettingsView.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI
import Carbon

struct SettingsView: View {
    @EnvironmentObject var controller: MenuBarController
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var modeManager = ModeManager.shared

    var body: some View {
        TabView {
                GeneralTab(controller: controller, settings: settings)
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }

                ModesTab(settings: settings, modeManager: modeManager)
                    .tabItem {
                        Label("Modes", systemImage: "sparkles")
                    }

                ProvidersTab(modeManager: modeManager)
                    .tabItem {
                        Label("Providers", systemImage: "cpu")
                    }
            }
            .padding(.top, 8)
    }
}

// MARK: - General Tab
struct GeneralTab: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Shortcuts Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shortcuts")
                        .font(.headline)

                    // Capturing shortcut
                    ShortcutRow(
                        icon: "mic.fill",
                        iconColor: .blue,
                        title: "Start/Stop Capturing",
                        keyCode: $settings.capturingShortcutKeyCode,
                        modifiers: $settings.capturingShortcutModifiers,
                        onReset: {
                            settings.resetCapturingShortcut()
                            controller.updateGlobalShortcut()
                        },
                        onChange: {
                            settings.saveSettings()
                            controller.updateGlobalShortcut()
                        }
                    )

                    // Toggle recording shortcut
                    ShortcutRow(
                        icon: "record.circle",
                        iconColor: .red,
                        title: "Toggle Recording in Capture",
                        keyCode: $settings.toggleRecordingShortcutKeyCode,
                        modifiers: $settings.toggleRecordingShortcutModifiers,
                        onReset: {
                            settings.resetToggleRecordingShortcut()
                            controller.updateGlobalShortcut()
                        },
                        onChange: {
                            settings.saveSettings()
                            controller.updateGlobalShortcut()
                        }
                    )

                    // Add clipboard shortcut
                    ShortcutRow(
                        icon: "doc.on.clipboard",
                        iconColor: .green,
                        title: "Add Clipboard to Capture",
                        keyCode: $settings.addClipboardShortcutKeyCode,
                        modifiers: $settings.addClipboardShortcutModifiers,
                        onReset: {
                            settings.resetAddClipboardShortcut()
                            controller.updateGlobalShortcut()
                        },
                        onChange: {
                            settings.saveSettings()
                            controller.updateGlobalShortcut()
                        }
                    )

                    // Preview capture shortcut
                    ShortcutRow(
                        icon: "list.bullet.rectangle",
                        iconColor: .purple,
                        title: "Preview Capture",
                        keyCode: $settings.previewShortcutKeyCode,
                        modifiers: $settings.previewShortcutModifiers,
                        onReset: {
                            settings.resetPreviewShortcut()
                            controller.updateGlobalShortcut()
                        },
                        onChange: {
                            settings.saveSettings()
                            controller.updateGlobalShortcut()
                        }
                    )
                }

                Divider()

                // Voice Processing Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Voice Processing")
                        .font(.headline)

                    HStack(spacing: 20) {
                        HStack(spacing: 6) {
                            Image(systemName: settings.whisperTask == "transcribe" ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(settings.whisperTask == "transcribe" ? .blue : .gray)
                            Text("Transcribe")
                                .font(.subheadline)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            settings.whisperTask = "transcribe"
                            settings.saveSettings()
                        }

                        HStack(spacing: 6) {
                            Image(systemName: settings.whisperTask == "translate" ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(settings.whisperTask == "translate" ? .blue : .gray)
                            Text("Translate")
                                .font(.subheadline)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            settings.whisperTask = "translate"
                            settings.saveSettings()
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Provider Global Settings Section
struct ProviderGlobalSettingsSection: View {
    let onAddOllama: () -> Void
    @State private var ollamaSettings = GlobalProviderSettingsStorage.shared.loadOllamaSettings()
    @State private var anthropicSettings = GlobalProviderSettingsStorage.shared.loadAnthropicSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Provider Settings")
                .font(.headline)

            Text("Configure default settings for LLM providers")
                .font(.caption)
                .foregroundColor(.secondary)

            // Ollama Settings
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .foregroundColor(.secondary)
                    Text("Ollama")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Base URL")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("http://localhost:11434", text: $ollamaSettings.defaultBaseURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: ollamaSettings.defaultBaseURL) { _, _ in
                            GlobalProviderSettingsStorage.shared.saveOllamaSettings(ollamaSettings)
                        }

                    Text("Default URL for new Ollama models (can be overridden per model)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 28)

                // Add Model button
                Button(action: onAddOllama) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Model")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 28)
                .padding(.top, 4)
            }
            .padding(.vertical, 8)

            Divider()

            // Anthropic Settings
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .foregroundColor(.secondary)
                    Text("Anthropic")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    SecureField("sk-ant-...", text: $anthropicSettings.apiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: anthropicSettings.apiKey) { _, _ in
                            GlobalProviderSettingsStorage.shared.saveAnthropicSettings(anthropicSettings)
                        }

                    Text("Get your API key from console.anthropic.com")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 28)

                // Add Anthropic Model button
                Button(action: {
                    // TODO: Implement add Anthropic model
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Model")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 28)
                .padding(.top, 4)
                .disabled(anthropicSettings.apiKey.isEmpty)
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Providers Tab
struct ProvidersTab: View {
    @ObservedObject var modeManager: ModeManager
    @State private var showingAddProvider = false
    @State private var editingProvider: ProviderConfiguration?
    @State private var providerAvailability: [UUID: Bool] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Provider Global Settings
                ProviderGlobalSettingsSection(onAddOllama: { showingAddProvider = true })
                    .padding(.top, 8)

                Divider()

                // Configured Models Header
                Text("Configured Models")
                    .font(.headline)

                Text("Models you've added and configured")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Provider list
                VStack(spacing: 12) {
                    ForEach(modeManager.providerConfigurations) { config in
                        ProviderRow(
                            config: config,
                            isActive: modeManager.activeLLMProvider.id == config.id,
                            isAvailable: providerAvailability[config.id] ?? false,
                            onEdit: { editingProvider = config },
                            onDelete: { modeManager.deleteProviderConfiguration(config) }
                        )
                    }
                }

                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingAddProvider) {
            AddProviderSheet(modeManager: modeManager, isPresented: $showingAddProvider)
        }
        .sheet(item: $editingProvider) { config in
            EditProviderSheet(config: config, modeManager: modeManager, isPresented: Binding(
                get: { editingProvider != nil },
                set: { if !$0 { editingProvider = nil } }
            ))
        }
        .task {
            await checkProviderAvailability()
        }
    }

    private func checkProviderAvailability() async {
        for provider in modeManager.availableProviders {
            let available = await provider.isAvailable
            await MainActor.run {
                providerAvailability[provider.id] = available
            }
        }
    }
}

// MARK: - Provider Row Component
struct ProviderRow: View {
    let config: ProviderConfiguration
    let isActive: Bool
    let isAvailable: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Provider icon and name
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: providerIcon)
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))

                        Text(config.displayName)
                            .font(.subheadline)

                        // Action buttons right after name
                        if config.providerType == .ollama || config.providerType == .anthropic {
                            Button(action: onEdit) {
                                Image(systemName: "pencil")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(PlainButtonStyle())

                            Button(action: onDelete) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if isActive {
                            Text("Default")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                        }

                        Spacer()

                        // Availability indicator
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isAvailable ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(isAvailable ? "Available" : "Unavailable")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Provider details
                    if config.providerType == .ollama {
                        VStack(alignment: .leading, spacing: 2) {
                            if let modelName = config.ollamaModelName {
                                Text("Model: \(modelName)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let baseURL = config.ollamaBaseURL {
                                Text("URL: \(baseURL)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading, 24)
                    } else if config.providerType == .anthropic {
                        VStack(alignment: .leading, spacing: 2) {
                            if let modelName = config.anthropicModelName {
                                Text("Model: \(modelName)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
    }

    private var providerIcon: String {
        switch config.providerType {
        case .appleFoundationModels:
            return "apple.logo"
        case .ollama:
            return "cpu"
        case .anthropic:
            return "sparkle"
        }
    }
}

// MARK: - Add Provider Sheet
struct AddProviderSheet: View {
    @ObservedObject var modeManager: ModeManager
    @Binding var isPresented: Bool

    @State private var modelName: String = "llama3.2:3b"
    @State private var baseURL: String = GlobalProviderSettingsStorage.shared.loadOllamaSettings().defaultBaseURL
    @State private var useCustomURL: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Model")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., llama3.2:3b", text: $modelName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Text("Must be already pulled via 'ollama pull <model>'")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $useCustomURL) {
                        Text("Use custom URL")
                            .font(.caption)
                    }

                    if useCustomURL {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("http://localhost:11434", text: $baseURL)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("Override default URL for this model")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Using default: \(GlobalProviderSettingsStorage.shared.loadOllamaSettings().defaultBaseURL)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Preview of generated name
            if !modelName.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Will appear as:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(previewName)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }

                Button("Add") {
                    let finalBaseURL = useCustomURL ? baseURL : GlobalProviderSettingsStorage.shared.loadOllamaSettings().defaultBaseURL
                    let config = ProviderConfiguration.ollama(
                        modelName: modelName,
                        baseURL: finalBaseURL
                    )
                    modeManager.addProviderConfiguration(config)
                    isPresented = false
                }
                .disabled(modelName.isEmpty || (useCustomURL && baseURL.isEmpty))
            }
        }
        .padding()
        .frame(width: 400)
    }

    private var previewName: String {
        let finalBaseURL = useCustomURL ? baseURL : GlobalProviderSettingsStorage.shared.loadOllamaSettings().defaultBaseURL
        let config = ProviderConfiguration.ollama(modelName: modelName, baseURL: finalBaseURL)
        return config.displayName
    }
}

// MARK: - Edit Provider Sheet
struct EditProviderSheet: View {
    let config: ProviderConfiguration
    @ObservedObject var modeManager: ModeManager
    @Binding var isPresented: Bool

    @State private var modelName: String
    @State private var baseURL: String
    @State private var useCustomURL: Bool

    init(config: ProviderConfiguration, modeManager: ModeManager, isPresented: Binding<Bool>) {
        self.config = config
        self.modeManager = modeManager
        self._isPresented = isPresented

        let currentBaseURL = config.ollamaBaseURL ?? "http://localhost:11434"
        let defaultBaseURL = GlobalProviderSettingsStorage.shared.loadOllamaSettings().defaultBaseURL

        self._modelName = State(initialValue: config.ollamaModelName ?? "llama3.2:3b")
        self._baseURL = State(initialValue: currentBaseURL)
        self._useCustomURL = State(initialValue: currentBaseURL != defaultBaseURL)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Model")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., llama3.2:3b", text: $modelName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Text("Must be already pulled via 'ollama pull <model>'")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $useCustomURL) {
                        Text("Use custom URL")
                            .font(.caption)
                    }

                    if useCustomURL {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("http://localhost:11434", text: $baseURL)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("Override default URL for this model")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Using default: \(GlobalProviderSettingsStorage.shared.loadOllamaSettings().defaultBaseURL)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Preview of generated name
            if !modelName.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Will appear as:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(previewName)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }

                Button("Save") {
                    let finalBaseURL = useCustomURL ? baseURL : GlobalProviderSettingsStorage.shared.loadOllamaSettings().defaultBaseURL
                    var updated = config
                    updated.ollamaModelName = modelName
                    updated.ollamaBaseURL = finalBaseURL
                    modeManager.updateProviderConfiguration(updated)
                    isPresented = false
                }
                .disabled(modelName.isEmpty || (useCustomURL && baseURL.isEmpty))
            }
        }
        .padding()
        .frame(width: 400)
    }

    private var previewName: String {
        let finalBaseURL = useCustomURL ? baseURL : GlobalProviderSettingsStorage.shared.loadOllamaSettings().defaultBaseURL
        let tempConfig = ProviderConfiguration.ollama(modelName: modelName, baseURL: finalBaseURL)
        return tempConfig.displayName
    }
}

// MARK: - Modes Tab
struct ModesTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var modeManager: ModeManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Default Provider Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Default Provider")
                        .font(.headline)

                    Text("Select which LLM provider to use for processing modes")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(spacing: 8) {
                        ForEach(modeManager.availableProviders, id: \.id) { provider in
                            Button(action: {
                                modeManager.setProvider(provider)
                            }) {
                                HStack {
                                    Image(systemName: provider.id == modeManager.activeLLMProvider.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(provider.id == modeManager.activeLLMProvider.id ? .blue : .gray)

                                    Text(provider.name)
                                        .font(.subheadline)

                                    Spacer()
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.vertical, 8)

                    if modeManager.availableProviders.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("No providers configured. Go to Providers tab to add one.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.top, 8)

                Divider()

                // Custom Modes Section
                CustomModesSection()

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Shortcut Row Component
struct ShortcutRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var keyCode: CGKeyCode
    @Binding var modifiers: CGEventFlags
    let onReset: () -> Void
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .frame(width: 220, alignment: .leading)

            ShortcutRecorderView(
                keyCode: $keyCode,
                modifiers: $modifiers
            )
            .onChange(of: keyCode) { _, _ in
                onChange()
            }
            .onChange(of: modifiers) { _, _ in
                onChange()
            }

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(MenuBarController())
}
