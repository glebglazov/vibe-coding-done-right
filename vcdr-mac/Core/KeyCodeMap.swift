import CoreGraphics

/// Single source-of-truth for US ANSI virtual key code mappings.
/// Used by GlobalHotkeyManager (display names), OutputDestination (legacy migration),
/// and KeyboardSimulator (key constants).
// TODO: This mapping assumes a US ANSI keyboard layout. Key codes are hardware
// constants, so e.g. code 44 is "/" on US but a different character on other layouts.
// Two options to fix: (1) use UCKeyTranslate / TISCopyCurrentKeyboardInputSource to
// resolve key codes dynamically based on the active input source, or (2) capture the
// character from the NSEvent at recording time and store it alongside the key code.
enum KeyCodeMap {
    // MARK: - Constants

    static let cKeyCode: UInt16 = 8
    static let vKeyCode: UInt16 = 9
    static let spaceKeyCode: UInt16 = 49
    static let slashKeyCode: UInt16 = 44

    // MARK: - Navigation Key Codes

    static let returnKeyCode: UInt16 = 36
    static let escapeKeyCode: UInt16 = 53
    static let tabKeyCode: UInt16 = 48
    static let leftArrowKeyCode: UInt16 = 123
    static let rightArrowKeyCode: UInt16 = 124
    static let downArrowKeyCode: UInt16 = 125
    static let upArrowKeyCode: UInt16 = 126

    // Vim-style navigation
    static let hKeyCode: UInt16 = 4
    static let jKeyCode: UInt16 = 38
    static let kKeyCode: UInt16 = 40
    static let lKeyCode: UInt16 = 37

    // MARK: - Code → Name

    static let codeToName: [CGKeyCode: String] = [
        // Letters
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        // Numbers
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        25: "9", 26: "7", 28: "8", 29: "0",
        // Punctuation
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
        42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        // Special keys
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
        // Arrow keys
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Returns the display name for a key code, or "Key<N>" for unknown codes.
    static func name(for keyCode: CGKeyCode) -> String {
        codeToName[keyCode] ?? "Key\(keyCode)"
    }

    // MARK: - Character → Code

    /// Returns the key code for a character (case-insensitive), or nil if not mapped.
    /// Covers letters, digits, and punctuation — the subset needed for legacy migration.
    static func keyCode(for character: Character) -> UInt16? {
        nameToCode[String(character).lowercased()]
    }

    /// Reverse mapping from lowercase single-character name to key code.
    private static let nameToCode: [String: UInt16] = {
        var result: [String: UInt16] = [:]
        for (code, name) in codeToName {
            let lower = name.lowercased()
            // Only include single-character names (letters, digits, punctuation)
            if lower.count == 1 {
                result[lower] = UInt16(code)
            }
        }
        return result
    }()
}
