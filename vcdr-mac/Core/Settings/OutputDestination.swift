import Foundation
import CoreGraphics

enum OutputDestinationType: String, Codable, CaseIterable {
    case paste
    case pasteToInitialApp
    case bashScript
    case copy

    /// Types available for user-created destinations (excludes special built-in types)
    static var userCreatable: [OutputDestinationType] {
        [.bashScript]
    }

    var displayName: String {
        switch self {
        case .paste: "Paste (Cmd+V)"
        case .pasteToInitialApp: "Paste to Initial App"
        case .bashScript: "Bash Script"
        case .copy: "Copy to Clipboard"
        }
    }
}

struct OutputDestination: Identifiable, Equatable {
    let id: UUID
    var name: String
    var type: OutputDestinationType
    var bashCommand: String
    var symbol: String
    var activationHotkey: HotkeyBinding

    var isBuiltIn: Bool { type == .paste || type == .pasteToInitialApp || type == .copy }

    /// Derives a display character from the hotkey's keyCode (e.g. keyCode 8 → "C").
    /// Used in the mode switcher for bare-key matching and display.
    var activationKeyCharacter: String {
        guard activationHotkey.isAssigned else { return "" }
        return KeyCodeMap.name(for: CGKeyCode(activationHotkey.keyCode))
    }

    // MARK: - Constants

    /// Well-known ID for the built-in Paste destination.
    /// Used for migration and as default fallback when a mode's destination is missing.
    static let builtInPasteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func makeDefaultPaste() -> OutputDestination {
        OutputDestination(
            id: builtInPasteID,
            name: "Paste",
            type: .paste,
            bashCommand: "",
            symbol: "📋",
            activationHotkey: HotkeyBinding(
                keyCode: 35, // P
                modifiers: UInt64(CGEventFlags.maskAlternate.rawValue)
            )
        )
    }

    /// Well-known ID for the built-in Copy destination.
    static let builtInCopyID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static func makeDefaultCopy() -> OutputDestination {
        OutputDestination(
            id: builtInCopyID,
            name: "Copy",
            type: .copy,
            bashCommand: "",
            symbol: "📄",
            activationHotkey: HotkeyBinding(
                keyCode: 8, // C
                modifiers: UInt64(CGEventFlags.maskAlternate.rawValue)
            )
        )
    }

    /// Well-known ID for the built-in Paste to Initial App destination.
    static let builtInPasteToInitialAppID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    static func makeDefaultPasteToInitialApp() -> OutputDestination {
        OutputDestination(
            id: builtInPasteToInitialAppID,
            name: "Paste to Initial App",
            type: .pasteToInitialApp,
            bashCommand: "",
            symbol: "📌",
            activationHotkey: HotkeyBinding(
                keyCode: 35, // P
                modifiers: UInt64(CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue)
            )
        )
    }

    static func makeNewBashScript(name: String = "New Destination") -> OutputDestination {
        OutputDestination(
            id: UUID(),
            name: name,
            type: .bashScript,
            bashCommand: "echo $VCDR_TEXT",
            symbol: "⚡",
            activationHotkey: .unassigned
        )
    }
}

// MARK: - Codable (with legacy activationKey migration)

extension OutputDestination: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, type, bashCommand, symbol, activationHotkey
        // Legacy key for migration
        case activationKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(OutputDestinationType.self, forKey: .type)
        bashCommand = try container.decode(String.self, forKey: .bashCommand)
        symbol = try container.decode(String.self, forKey: .symbol)

        if let hotkey = try container.decodeIfPresent(HotkeyBinding.self, forKey: .activationHotkey) {
            activationHotkey = hotkey
        } else if let legacyKey = try container.decodeIfPresent(String.self, forKey: .activationKey) {
            // Migrate legacy single-character activationKey → HotkeyBinding with Ctrl modifier
            activationHotkey = Self.migrateActivationKey(legacyKey)
        } else {
            activationHotkey = .unassigned
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(bashCommand, forKey: .bashCommand)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(activationHotkey, forKey: .activationHotkey)
    }

    /// Converts a legacy single-character activation key to a HotkeyBinding.
    /// Maps the character to a keyCode using KeyCodeMap, with Option as default modifier.
    private static func migrateActivationKey(_ key: String) -> HotkeyBinding {
        guard let char = key.lowercased().first else { return .unassigned }
        guard let keyCode = KeyCodeMap.keyCode(for: char) else { return .unassigned }
        return HotkeyBinding(
            keyCode: keyCode,
            modifiers: UInt64(CGEventFlags.maskAlternate.rawValue)
        )
    }
}
