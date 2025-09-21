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

    @Published var shortcutKeyCode: CGKeyCode = 49 // Space bar
    @Published var shortcutModifiers: CGEventFlags = [.maskCommand, .maskShift] // Cmd+Shift

    private let userDefaults = UserDefaults.standard

    private init() {
        loadSettings()
    }

    func loadSettings() {
        shortcutKeyCode = CGKeyCode(userDefaults.integer(forKey: "shortcutKeyCode"))
        if shortcutKeyCode == 0 {
            shortcutKeyCode = 49 // Default to Space
        }

        let modifierRawValue = userDefaults.integer(forKey: "shortcutModifiers")
        if modifierRawValue == 0 {
            shortcutModifiers = [.maskCommand, .maskShift] // Default
        } else {
            shortcutModifiers = CGEventFlags(rawValue: UInt64(modifierRawValue))
        }
    }

    func saveSettings() {
        userDefaults.set(Int(shortcutKeyCode), forKey: "shortcutKeyCode")
        userDefaults.set(Int(shortcutModifiers.rawValue), forKey: "shortcutModifiers")
    }

    var shortcutDisplayString: String {
        var components: [String] = []

        if shortcutModifiers.contains(.maskCommand) {
            components.append("⌘")
        }
        if shortcutModifiers.contains(.maskShift) {
            components.append("⇧")
        }
        if shortcutModifiers.contains(.maskAlternate) {
            components.append("⌥")
        }
        if shortcutModifiers.contains(.maskControl) {
            components.append("⌃")
        }

        // Add the key name
        components.append(keyNameForKeyCode(shortcutKeyCode))

        return components.joined()
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