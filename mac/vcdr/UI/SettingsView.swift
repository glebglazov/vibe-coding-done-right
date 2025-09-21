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
                    Text("• Choose between Tmux (Claude) and Clipboard (Auto-paste) destinations")
                    Text("• Accessibility permissions are required for auto-paste functionality")
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