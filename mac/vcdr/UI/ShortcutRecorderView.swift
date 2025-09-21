//
//  ShortcutRecorderView.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI
import Carbon

struct ShortcutRecorderView: View {
    @Binding var keyCode: CGKeyCode
    @Binding var modifiers: CGEventFlags
    @State private var isRecording = false
    @State private var temporaryShortcut: String = ""

    var currentShortcutDisplay: String {
        var components: [String] = []

        if modifiers.contains(.maskCommand) {
            components.append("⌘")
        }
        if modifiers.contains(.maskShift) {
            components.append("⇧")
        }
        if modifiers.contains(.maskAlternate) {
            components.append("⌥")
        }
        if modifiers.contains(.maskControl) {
            components.append("⌃")
        }

        components.append(keyNameForKeyCode(keyCode))
        return components.joined()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global Shortcut")
                .font(.headline)

            HStack {
                Button(action: {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }) {
                    HStack {
                        if isRecording {
                            Text(temporaryShortcut.isEmpty ? "Press keys..." : temporaryShortcut)
                                .foregroundColor(.orange)
                        } else {
                            Text(currentShortcutDisplay)
                                .foregroundColor(.primary)
                        }

                        Spacer()

                        if isRecording {
                            Image(systemName: "record.circle.fill")
                                .foregroundColor(.red)
                        } else {
                            Image(systemName: "pencil")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isRecording ? Color.orange : Color.gray.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                if isRecording {
                    Button("Cancel") {
                        stopRecording()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if isRecording {
                Text("Press any key combination to record it as your shortcut")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Click to record a new shortcut")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            setupKeyMonitoring()
        }
    }

    private func startRecording() {
        isRecording = true
        temporaryShortcut = ""
    }

    private func stopRecording() {
        isRecording = false
        temporaryShortcut = ""
    }

    private func setupKeyMonitoring() {
        // Add both global and local monitors for better compatibility
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            self.handleKeyEvent(event)
        }

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            self.handleKeyEvent(event)
            return event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard isRecording else { return }

        if event.type == .keyDown {
            let newKeyCode = CGKeyCode(event.keyCode)
            let newModifiers = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                .intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

            // Update the binding values
            DispatchQueue.main.async {
                self.keyCode = newKeyCode
                self.modifiers = newModifiers
                self.isRecording = false
                self.temporaryShortcut = ""
            }
        } else if event.type == .flagsChanged {
            // Show temporary preview while holding modifiers
            let currentModifiers = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                .intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

            var components: [String] = []
            if currentModifiers.contains(.maskCommand) {
                components.append("⌘")
            }
            if currentModifiers.contains(.maskShift) {
                components.append("⇧")
            }
            if currentModifiers.contains(.maskAlternate) {
                components.append("⌥")
            }
            if currentModifiers.contains(.maskControl) {
                components.append("⌃")
            }

            DispatchQueue.main.async {
                self.temporaryShortcut = components.joined() + (components.isEmpty ? "" : "+")
            }
        }
    }

    private func keyNameForKeyCode(_ keyCode: CGKeyCode) -> String {
        switch keyCode {
        case 49: return "Space"
        case 53: return "Esc"
        case 36: return "Enter"
        case 48: return "Tab"
        case 51: return "Delete"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return "Key(\(keyCode))"
        }
    }
}

#Preview {
    @State var keyCode: CGKeyCode = 49
    @State var modifiers: CGEventFlags = [.maskCommand, .maskShift]

    return ShortcutRecorderView(keyCode: $keyCode, modifiers: $modifiers)
        .padding()
}