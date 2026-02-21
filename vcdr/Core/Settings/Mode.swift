import Foundation

struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var actionType: PostTranscriptionActionType
    var bashCommand: String
    var terminatorTemplateEnabled: Bool
    var terminatorTemplate: String
    var systemPromptEnabled: Bool
    var systemPrompt: String

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
        terminatorTemplate: String = defaultTerminatorTemplate,
        systemPromptEnabled: Bool = false,
        systemPrompt: String = ""
    ) {
        self.id = id
        self.name = name
        self.actionType = actionType
        self.bashCommand = bashCommand
        self.terminatorTemplateEnabled = terminatorTemplateEnabled
        self.terminatorTemplate = terminatorTemplate
        self.systemPromptEnabled = systemPromptEnabled
        self.systemPrompt = systemPrompt
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
        systemPromptEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemPromptEnabled) ?? false
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
    }
}
