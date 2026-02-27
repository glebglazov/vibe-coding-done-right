import Foundation

enum OutputDestinationType: String, Codable, CaseIterable {
    case paste
    case bashScript
    case outputPanel

    /// Types available for user-created destinations (excludes special built-in types)
    static var userCreatable: [OutputDestinationType] {
        [.bashScript]
    }

    var displayName: String {
        switch self {
        case .paste: "Paste (Cmd+V)"
        case .bashScript: "Bash Script"
        case .outputPanel: "Output Panel"
        }
    }
}

struct OutputDestination: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: OutputDestinationType
    var bashCommand: String
    var symbol: String
    var activationKey: String

    var isBuiltIn: Bool { type == .paste || type == .outputPanel }

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
            activationKey: "p"
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
            activationKey: "o"
        )
    }

    static func makeNewBashScript(name: String = "New Destination") -> OutputDestination {
        OutputDestination(
            id: UUID(),
            name: name,
            type: .bashScript,
            bashCommand: "echo $VCDR_TEXT",
            symbol: "⚡",
            activationKey: ""
        )
    }
}
