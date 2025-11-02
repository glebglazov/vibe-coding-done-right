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
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)

                Text("vcdr settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("vibe coding done right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Tabs
            TabView {
                GeneralTab(settings: settings)
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }

                ShortcutsTab(controller: controller, settings: settings)
                    .tabItem {
                        Label("Shortcuts", systemImage: "keyboard")
                    }

                ModesTab(settings: settings, modeManager: modeManager)
                    .tabItem {
                        Label("Modes", systemImage: "sparkles")
                    }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shortcuts Tab
struct ShortcutsTab: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Global Shortcuts")
                    .font(.headline)
                    .padding(.top, 8)

                // Capturing shortcut
                ShortcutRow(
                    icon: "mic.fill",
                    iconColor: .blue,
                    title: "Start/Stop Capturing",
                    description: "Press once to start capturing, press again to close",
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

                Divider()
                    .padding(.vertical, 4)

                // Toggle recording shortcut
                ShortcutRow(
                    icon: "record.circle",
                    iconColor: .red,
                    title: "Toggle Recording in Capture",
                    description: "Start/stop recording while capture is active",
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

                Divider()
                    .padding(.vertical, 4)

                // Add clipboard shortcut
                ShortcutRow(
                    icon: "doc.on.clipboard",
                    iconColor: .green,
                    title: "Add Clipboard to Capture",
                    description: "Add clipboard text to current capture",
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

                Divider()
                    .padding(.vertical, 4)

                // Preview capture shortcut
                ShortcutRow(
                    icon: "list.bullet.rectangle",
                    iconColor: .purple,
                    title: "Preview Capture",
                    description: "Open preview window to see all capture actions",
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

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - General Tab
struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Voice Processing Section
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Voice Processing")
                            .font(.headline)

                        VStack(spacing: 8) {
                            HStack {
                                Button(action: {
                                    settings.whisperTask = "transcribe"
                                    settings.saveSettings()
                                }) {
                                    HStack {
                                        Image(systemName: settings.whisperTask == "transcribe" ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(settings.whisperTask == "transcribe" ? .blue : .gray)
                                        Text("Transcribe")
                                            .font(.subheadline)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }

                            Text("Keep original language (Russian → Russian, English → English)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 28)

                            HStack {
                                Button(action: {
                                    settings.whisperTask = "translate"
                                    settings.saveSettings()
                                }) {
                                    HStack {
                                        Image(systemName: settings.whisperTask == "translate" ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(settings.whisperTask == "translate" ? .blue : .gray)
                                        Text("Translate")
                                            .font(.subheadline)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }

                            Text("Translate to English (Russian → English, Spanish → English)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 28)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Modes Tab
struct ModesTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var modeManager: ModeManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Info Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                        Text("Select mode in capturing overlay")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(.secondary)
                        Text("Provider: \(modeManager.activeLLMProvider.name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
    let description: String
    @Binding var keyCode: CGKeyCode
    @Binding var modifiers: CGEventFlags
    let onReset: () -> Void
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 24)

            HStack {
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
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Reset shortcut")
            }
            .padding(.leading, 24)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(MenuBarController())
}
