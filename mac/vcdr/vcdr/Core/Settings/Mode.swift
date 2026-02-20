import Foundation

struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var actionType: PostTranscriptionActionType
    var bashCommand: String
    var terminatorTemplateEnabled: Bool
    var terminatorTemplate: String

    // MARK: - Constants

    static let defaultTerminatorTemplate = "<dot><space>"

    static func makeDefault() -> Mode {
        Mode(
            id: UUID(),
            name: "Default",
            actionType: .paste,
            bashCommand: "echo {}"
        )
    }

    init(
        id: UUID,
        name: String,
        actionType: PostTranscriptionActionType,
        bashCommand: String,
        terminatorTemplateEnabled: Bool = false,
        terminatorTemplate: String = defaultTerminatorTemplate
    ) {
        self.id = id
        self.name = name
        self.actionType = actionType
        self.bashCommand = bashCommand
        self.terminatorTemplateEnabled = terminatorTemplateEnabled
        self.terminatorTemplate = terminatorTemplate
    }

    // MARK: - Codable (backward-compatible)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        actionType = try container.decode(PostTranscriptionActionType.self, forKey: .actionType)
        bashCommand = try container.decode(String.self, forKey: .bashCommand)
        terminatorTemplateEnabled = try container.decodeIfPresent(Bool.self, forKey: .terminatorTemplateEnabled) ?? false
        terminatorTemplate = try container.decodeIfPresent(String.self, forKey: .terminatorTemplate) ?? Self.defaultTerminatorTemplate
    }
}
