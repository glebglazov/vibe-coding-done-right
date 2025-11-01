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

    // Capturing shortcut (toggle overlay)
    @Published var capturingShortcutKeyCode: CGKeyCode = 49 // Space bar
    @Published var capturingShortcutModifiers: CGEventFlags = [.maskCommand, .maskShift] // Cmd+Shift

    // Toggle recording in capture shortcut
    @Published var toggleRecordingShortcutKeyCode: CGKeyCode = 15 // R key
    @Published var toggleRecordingShortcutModifiers: CGEventFlags = [.maskCommand, .maskControl] // Cmd+Ctrl+R

    // Add clipboard to capture shortcut
    @Published var addClipboardShortcutKeyCode: CGKeyCode = 8 // C key
    @Published var addClipboardShortcutModifiers: CGEventFlags = [.maskCommand, .maskControl] // Cmd+Ctrl+C

    @Published var whisperTask: String = "transcribe" // "transcribe" or "translate"

    // Mode settings
    @Published var isModeEnabled: Bool = true
    @Published var activeModeName: String = "Disabled" // Name of the active mode

    private let userDefaults = UserDefaults.standard

    private init() {
        loadSettings()
    }

    func loadSettings() {
        // Load capturing shortcut (keeping UserDefaults key as "recording" for backwards compatibility)
        let capturingKeyCode = userDefaults.integer(forKey: "recordingShortcutKeyCode")
        if capturingKeyCode == 0 && userDefaults.object(forKey: "recordingShortcutKeyCode") == nil {
            // First time launch - set default
            capturingShortcutKeyCode = 49 // Default to Space
            capturingShortcutModifiers = [.maskCommand, .maskShift]
        } else {
            capturingShortcutKeyCode = CGKeyCode(capturingKeyCode)
            let capturingModifierRawValue = userDefaults.integer(forKey: "recordingShortcutModifiers")
            capturingShortcutModifiers = CGEventFlags(rawValue: UInt64(capturingModifierRawValue))
        }

        // Load toggle recording shortcut
        let toggleRecordingKeyCode = userDefaults.integer(forKey: "toggleRecordingShortcutKeyCode")
        if toggleRecordingKeyCode == 0 && userDefaults.object(forKey: "toggleRecordingShortcutKeyCode") == nil {
            // First time launch - set default
            toggleRecordingShortcutKeyCode = 15 // R key
            toggleRecordingShortcutModifiers = [.maskCommand, .maskControl]
        } else {
            toggleRecordingShortcutKeyCode = CGKeyCode(toggleRecordingKeyCode)
            let toggleRecordingModifierRawValue = userDefaults.integer(forKey: "toggleRecordingShortcutModifiers")
            toggleRecordingShortcutModifiers = CGEventFlags(rawValue: UInt64(toggleRecordingModifierRawValue))
        }

        // Load add clipboard shortcut
        let addClipboardKeyCode = userDefaults.integer(forKey: "addClipboardShortcutKeyCode")
        if addClipboardKeyCode == 0 && userDefaults.object(forKey: "addClipboardShortcutKeyCode") == nil {
            // First time launch - set default
            addClipboardShortcutKeyCode = 8 // C key
            addClipboardShortcutModifiers = [.maskCommand, .maskControl]
        } else {
            addClipboardShortcutKeyCode = CGKeyCode(addClipboardKeyCode)
            let addClipboardModifierRawValue = userDefaults.integer(forKey: "addClipboardShortcutModifiers")
            addClipboardShortcutModifiers = CGEventFlags(rawValue: UInt64(addClipboardModifierRawValue))
        }

        whisperTask = userDefaults.string(forKey: "whisperTask") ?? "transcribe"

        // Load mode settings
        if userDefaults.object(forKey: "isModeEnabled") == nil {
            // First time launch - default to enabled
            isModeEnabled = true
        } else {
            isModeEnabled = userDefaults.bool(forKey: "isModeEnabled")
        }
        activeModeName = userDefaults.string(forKey: "activeModeName") ?? "Disabled"
    }

    func saveSettings() {
        userDefaults.set(Int(capturingShortcutKeyCode), forKey: "recordingShortcutKeyCode")
        userDefaults.set(Int(capturingShortcutModifiers.rawValue), forKey: "recordingShortcutModifiers")

        userDefaults.set(Int(toggleRecordingShortcutKeyCode), forKey: "toggleRecordingShortcutKeyCode")
        userDefaults.set(Int(toggleRecordingShortcutModifiers.rawValue), forKey: "toggleRecordingShortcutModifiers")

        userDefaults.set(Int(addClipboardShortcutKeyCode), forKey: "addClipboardShortcutKeyCode")
        userDefaults.set(Int(addClipboardShortcutModifiers.rawValue), forKey: "addClipboardShortcutModifiers")

        userDefaults.set(whisperTask, forKey: "whisperTask")

        // Save mode settings
        userDefaults.set(isModeEnabled, forKey: "isModeEnabled")
        userDefaults.set(activeModeName, forKey: "activeModeName")
    }

    var capturingShortcutDisplayString: String {
        if capturingShortcutKeyCode == 0 {
            return "Not set"
        }
        return shortcutDisplayString(keyCode: capturingShortcutKeyCode, modifiers: capturingShortcutModifiers)
    }

    var isCapturingShortcutSet: Bool {
        return capturingShortcutKeyCode != 0
    }

    func resetCapturingShortcut() {
        capturingShortcutKeyCode = 0
        capturingShortcutModifiers = []
        saveSettings()
    }

    var toggleRecordingShortcutDisplayString: String {
        if toggleRecordingShortcutKeyCode == 0 {
            return "Not set"
        }
        return shortcutDisplayString(keyCode: toggleRecordingShortcutKeyCode, modifiers: toggleRecordingShortcutModifiers)
    }

    var isToggleRecordingShortcutSet: Bool {
        return toggleRecordingShortcutKeyCode != 0
    }

    func resetToggleRecordingShortcut() {
        toggleRecordingShortcutKeyCode = 0
        toggleRecordingShortcutModifiers = []
        saveSettings()
    }

    var addClipboardShortcutDisplayString: String {
        if addClipboardShortcutKeyCode == 0 {
            return "Not set"
        }
        return shortcutDisplayString(keyCode: addClipboardShortcutKeyCode, modifiers: addClipboardShortcutModifiers)
    }

    var isAddClipboardShortcutSet: Bool {
        return addClipboardShortcutKeyCode != 0
    }

    func resetAddClipboardShortcut() {
        addClipboardShortcutKeyCode = 0
        addClipboardShortcutModifiers = []
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

    func keyNameForKeyCode(_ keyCode: CGKeyCode) -> String {
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