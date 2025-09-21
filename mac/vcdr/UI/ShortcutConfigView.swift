//
//  ShortcutConfigView.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI
import Carbon

struct ShortcutConfigView: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    private let presetShortcuts: [(name: String, keyCode: CGKeyCode, modifiers: CGEventFlags)] = [
        ("Cmd+Shift+Space", 49, [.maskCommand, .maskShift]),
        ("Cmd+Shift+R", 15, [.maskCommand, .maskShift]),
        ("Cmd+Shift+V", 9, [.maskCommand, .maskShift]),
        ("Cmd+Shift+M", 46, [.maskCommand, .maskShift]),
        ("Cmd+Option+Space", 49, [.maskCommand, .maskAlternate]),
        ("Cmd+Option+R", 15, [.maskCommand, .maskAlternate]),
        ("F12", 111, []),
        ("Cmd+F12", 111, [.maskCommand])
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("Configure Global Shortcut")
                .font(.headline)
                .padding(.top)

            Text("Current shortcut: \(settings.shortcutDisplayString)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a preset:")
                    .font(.subheadline)
                    .fontWeight(.medium)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    ForEach(presetShortcuts.indices, id: \.self) { index in
                        let preset = presetShortcuts[index]
                        Button(action: {
                            selectPreset(preset)
                        }) {
                            Text(preset.name)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    isCurrentShortcut(preset) ? Color.blue : Color.gray.opacity(0.2)
                                )
                                .foregroundColor(
                                    isCurrentShortcut(preset) ? .white : .primary
                                )
                                .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Button("Apply") {
                    applySettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom)
        }
        .padding()
        .frame(width: 300, height: 250)
    }

    private func isCurrentShortcut(_ preset: (name: String, keyCode: CGKeyCode, modifiers: CGEventFlags)) -> Bool {
        return settings.shortcutKeyCode == preset.keyCode &&
               settings.shortcutModifiers == preset.modifiers
    }

    private func selectPreset(_ preset: (name: String, keyCode: CGKeyCode, modifiers: CGEventFlags)) {
        settings.shortcutKeyCode = preset.keyCode
        settings.shortcutModifiers = preset.modifiers
    }

    private func applySettings() {
        settings.saveSettings()
        controller.updateGlobalShortcut()
    }
}