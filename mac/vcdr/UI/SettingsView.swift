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

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)

                Text("VCDR Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Voice to Claude Done Right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top)

            Divider()

            // Destination Section
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output Destination")
                        .font(.headline)

                    VStack(spacing: 8) {
                        ForEach(0..<controller.availableDestinations.count, id: \.self) { index in
                            let destination = controller.availableDestinations[index]

                            HStack {
                                Button(action: {
                                    controller.selectedDestinationIndex = index
                                }) {
                                    HStack {
                                        Image(systemName: controller.selectedDestinationIndex == index ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(controller.selectedDestinationIndex == index ? .blue : .gray)
                                        Text(destination)
                                            .font(.subheadline)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }

                            if destination == "Clipboard (Auto-paste)" {
                                Text("Copy text and automatically paste with Cmd+V")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 28)
                            } else if destination == "Tmux (Claude)" {
                                Text("Send directly to Claude Code session in tmux")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                    .padding(.vertical, 8)
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

            // Global Shortcut Section
            VStack(alignment: .leading, spacing: 16) {
                ShortcutRecorderView(
                    keyCode: Binding(
                        get: { settings.shortcutKeyCode },
                        set: { newValue in
                            settings.shortcutKeyCode = newValue
                            settings.saveSettings()
                            controller.updateGlobalShortcut()
                        }
                    ),
                    modifiers: Binding(
                        get: { settings.shortcutModifiers },
                        set: { newValue in
                            settings.shortcutModifiers = newValue
                            settings.saveSettings()
                            controller.updateGlobalShortcut()
                        }
                    )
                )
            }

            Spacer()

            // Info section
            VStack(spacing: 8) {
                Text("Tips:")
                    .font(.caption)
                    .fontWeight(.medium)

                VStack(alignment: .leading, spacing: 4) {
                    Text("• Click the shortcut field and press any key combination to record it")
                    Text("• Use the global shortcut to start/stop recording from anywhere")
                    Text("• Clipboard destination requires accessibility permissions for auto-paste")
                    Text("• Tmux destination sends directly to Claude Code sessions")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

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