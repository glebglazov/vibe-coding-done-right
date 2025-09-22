//
//  AppSettings.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation
import Carbon
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Clipboard destination shortcut
    @Published var clipboardShortcutKeyCode: CGKeyCode = 49 // Space bar
    @Published var clipboardShortcutModifiers: CGEventFlags = [.maskCommand, .maskShift] // Cmd+Shift

    // Tmux destination shortcut
    @Published var tmuxShortcutKeyCode: CGKeyCode = 50 // Backtick (`)
    @Published var tmuxShortcutModifiers: CGEventFlags = [.maskCommand, .maskShift] // Cmd+Shift

    @Published var whisperTask: String = "transcribe" // "transcribe" or "translate"

    private let userDefaults = UserDefaults.standard

    private init() {
        loadSettings()
    }

    func loadSettings() {
        // Load clipboard shortcut
        let clipboardKeyCode = userDefaults.integer(forKey: "clipboardShortcutKeyCode")
        if clipboardKeyCode == 0 && userDefaults.object(forKey: "clipboardShortcutKeyCode") == nil {
            // First time launch - set default
            clipboardShortcutKeyCode = 49 // Default to Space
            clipboardShortcutModifiers = [.maskCommand, .maskShift]
        } else {
            clipboardShortcutKeyCode = CGKeyCode(clipboardKeyCode)
            let clipboardModifierRawValue = userDefaults.integer(forKey: "clipboardShortcutModifiers")
            clipboardShortcutModifiers = CGEventFlags(rawValue: UInt64(clipboardModifierRawValue))
        }

        // Load tmux shortcut
        let tmuxKeyCode = userDefaults.integer(forKey: "tmuxShortcutKeyCode")
        if tmuxKeyCode == 0 && userDefaults.object(forKey: "tmuxShortcutKeyCode") == nil {
            // First time launch - set default
            tmuxShortcutKeyCode = 50 // Default to Backtick
            tmuxShortcutModifiers = [.maskCommand, .maskShift]
        } else {
            tmuxShortcutKeyCode = CGKeyCode(tmuxKeyCode)
            let tmuxModifierRawValue = userDefaults.integer(forKey: "tmuxShortcutModifiers")
            tmuxShortcutModifiers = CGEventFlags(rawValue: UInt64(tmuxModifierRawValue))
        }

        whisperTask = userDefaults.string(forKey: "whisperTask") ?? "transcribe"
    }

    func saveSettings() {
        userDefaults.set(Int(clipboardShortcutKeyCode), forKey: "clipboardShortcutKeyCode")
        userDefaults.set(Int(clipboardShortcutModifiers.rawValue), forKey: "clipboardShortcutModifiers")
        userDefaults.set(Int(tmuxShortcutKeyCode), forKey: "tmuxShortcutKeyCode")
        userDefaults.set(Int(tmuxShortcutModifiers.rawValue), forKey: "tmuxShortcutModifiers")
        userDefaults.set(whisperTask, forKey: "whisperTask")
    }

    var clipboardShortcutDisplayString: String {
        if clipboardShortcutKeyCode == 0 {
            return "Not set"
        }
        return shortcutDisplayString(keyCode: clipboardShortcutKeyCode, modifiers: clipboardShortcutModifiers)
    }

    var tmuxShortcutDisplayString: String {
        if tmuxShortcutKeyCode == 0 {
            return "Not set"
        }
        return shortcutDisplayString(keyCode: tmuxShortcutKeyCode, modifiers: tmuxShortcutModifiers)
    }

    var isClipboardShortcutSet: Bool {
        return clipboardShortcutKeyCode != 0
    }

    var isTmuxShortcutSet: Bool {
        return tmuxShortcutKeyCode != 0
    }

    func resetClipboardShortcut() {
        clipboardShortcutKeyCode = 0
        clipboardShortcutModifiers = []
        saveSettings()
    }

    func resetTmuxShortcut() {
        tmuxShortcutKeyCode = 0
        tmuxShortcutModifiers = []
        saveSettings()
    }

    private func shortcutDisplayString(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
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

        // Add the key name
        components.append(keyNameForKeyCode(keyCode))

        return components.joined()
    }

    private func keyNameForKeyCode(_ keyCode: CGKeyCode) -> String {
        switch keyCode {
        case 49: return "Space"
        case 50: return "`"
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