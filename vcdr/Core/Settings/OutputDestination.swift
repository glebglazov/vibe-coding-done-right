import Foundation
import CoreGraphics

enum OutputDestinationType: String, Codable, CaseIterable {
    case paste
    case bashScript
    case outputPanel
    case copy

    /// Types available for user-created destinations (excludes special built-in types)
    static var userCreatable: [OutputDestinationType] {
        [.bashScript]
    }

    var displayName: String {
        switch self {
        case .paste: "Paste (Cmd+V)"
        case .bashScript: "Bash Script"
        case .outputPanel: "Output Panel"
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

    var isBuiltIn: Bool { type == .paste || type == .outputPanel || type == .copy }

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
                modifiers: UInt64(CGEventFlags.maskControl.rawValue)
            )
        )
    }

    /// Well-known ID for the built-in Output Panel destination.
    static let builtInOutputPanelID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    static func makeDefaultOutputPanel() -> OutputDestination {
        OutputDestination(
            id: builtInOutputPanelID,
            name: "Output Panel",
            type: .outputPanel,
            bashCommand: "",
            symbol: "👁",
            activationHotkey: HotkeyBinding(
                keyCode: 31, // O
                modifiers: UInt64(CGEventFlags.maskControl.rawValue)
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
                modifiers: UInt64(CGEventFlags.maskControl.rawValue)
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
    /// Maps the character to a keyCode using KeyCodeMap, with Ctrl as default modifier.
    private static func migrateActivationKey(_ key: String) -> HotkeyBinding {
        guard let char = key.lowercased().first else { return .unassigned }
        guard let keyCode = KeyCodeMap.keyCode(for: char) else { return .unassigned }
        return HotkeyBinding(
            keyCode: keyCode,
            modifiers: UInt64(CGEventFlags.maskControl.rawValue)
        )
    }
}
