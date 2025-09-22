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

                Text("vcdr settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("vibe coding done right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top)

            Divider()

            // Global Shortcuts Section
            VStack(alignment: .leading, spacing: 16) {
                Text("Global Shortcuts")
                    .font(.headline)

                // Clipboard shortcut
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                        Text("Clipboard (Auto-paste)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    Text("Copy text and automatically paste with Cmd+V")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 24)

                    HStack {
                        ShortcutRecorderView(
                            keyCode: $settings.clipboardShortcutKeyCode,
                            modifiers: $settings.clipboardShortcutModifiers
                        )
                        .onChange(of: settings.clipboardShortcutKeyCode) { _ in
                            settings.saveSettings()
                            controller.updateGlobalShortcuts()
                        }
                        .onChange(of: settings.clipboardShortcutModifiers) { _ in
                            settings.saveSettings()
                            controller.updateGlobalShortcuts()
                        }

                        Button(action: {
                            settings.resetClipboardShortcut()
                            controller.updateGlobalShortcuts()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Reset clipboard shortcut")
                    }
                    .padding(.leading, 24)
                }

                // Tmux shortcut
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "terminal")
                            .foregroundColor(.green)
                        Text("Tmux (Claude)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    Text("Send directly to Claude Code session in tmux")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 24)

                    HStack {
                        ShortcutRecorderView(
                            keyCode: $settings.tmuxShortcutKeyCode,
                            modifiers: $settings.tmuxShortcutModifiers
                        )
                        .onChange(of: settings.tmuxShortcutKeyCode) { _ in
                            settings.saveSettings()
                            controller.updateGlobalShortcuts()
                        }
                        .onChange(of: settings.tmuxShortcutModifiers) { _ in
                            settings.saveSettings()
                            controller.updateGlobalShortcuts()
                        }

                        Button(action: {
                            settings.resetTmuxShortcut()
                            controller.updateGlobalShortcuts()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Reset tmux shortcut")
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