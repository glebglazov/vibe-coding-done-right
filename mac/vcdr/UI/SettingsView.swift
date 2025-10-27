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
        VStack(spacing: 20) {
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
            .padding(.top)

            Divider()

            // Global Shortcut Section
            VStack(alignment: .leading, spacing: 16) {
                Text("Recording Shortcut")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.blue)
                        Text("Start/Stop Recording")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    Text("Press once to start recording, press again to stop and choose destination")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 24)

                    HStack {
                        ShortcutRecorderView(
                            keyCode: $settings.recordingShortcutKeyCode,
                            modifiers: $settings.recordingShortcutModifiers
                        )
                        .onChange(of: settings.recordingShortcutKeyCode) { _, _ in
                            settings.saveSettings()
                            controller.updateGlobalShortcut()
                        }
                        .onChange(of: settings.recordingShortcutModifiers) { _, _ in
                            settings.saveSettings()
                            controller.updateGlobalShortcut()
                        }

                        Button(action: {
                            settings.resetRecordingShortcut()
                            controller.updateGlobalShortcut()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Reset recording shortcut")
                    }
                    .padding(.leading, 24)
                }
            }

            Divider()

            // Whisper Task Section
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

            Divider()

            // Mode System Section
            VStack(alignment: .leading, spacing: 16) {
                Text("AI Processing")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    // Enable/Disable Toggle
                    Toggle(isOn: Binding(
                        get: { modeManager.isEnabled },
                        set: { newValue in
                            modeManager.isEnabled = newValue
                            settings.isModeEnabled = newValue
                            settings.saveSettings()
                        }
                    )) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.purple)
                            Text("Enable AI Processing")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle())

                    Text("Process transcribed text with AI before sending to destination")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 28)

                    if modeManager.isEnabled {
                        Divider()
                            .padding(.vertical, 4)

                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("Select mode in recording overlay")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 12)

                        HStack {
                            Image(systemName: "cpu")
                                .foregroundColor(.secondary)
                            Text("Provider: \(modeManager.activeLLMProvider.name)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 12)
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

#Preview {
    SettingsView()
        .environmentObject(MenuBarController())
}