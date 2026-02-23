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
    var pasteScriptOutput: Bool

    // MARK: - Constants

    static let defaultTerminatorTemplate = "<dot><space>"
    private static let sentenceEndingPunctuation: Set<Character> = [".", "?", "!"]

    // MARK: - Text Pipeline

    /// Transforms raw transcription text by applying the mode's terminator, system
    /// prompt (bash-only), and appending any captured selection from the frontmost app.
    func transformTranscription(_ text: String, capturedSelection: String?) -> String {
        var result = terminatorTemplateEnabled
            ? Self.applyTerminator(text, terminator: terminatorTemplate)
            : text

        if actionType == .bash && systemPromptEnabled && !systemPrompt.isEmpty {
            result = systemPrompt + "\n\n" + result
        }

        if let selection = capturedSelection {
            result += "\n\n" + selection
        }

        return result
    }

    /// Appends the mode's terminator to the transcription, separating punctuation
    /// from spacing. If the text already ends with sentence-ending punctuation,
    /// only the spacing portion of the terminator is appended (e.g. `"Hello."` with
    /// terminator `<dot><space>` becomes `"Hello. "`, not `"Hello."`).
    static func applyTerminator(_ text: String, terminator: String) -> String {
        guard !terminator.isEmpty else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.last != nil else { return text }

        let resolved = terminator
            .replacingOccurrences(of: "<dot>", with: ".")
            .replacingOccurrences(of: "<space>", with: " ")
            .replacingOccurrences(of: "<newline>", with: "\n")

        // Split resolved terminator into leading punctuation and trailing spacing.
        // If text already ends with punctuation, skip the punctuation part but
        // still append spacing so consecutive dictations are properly separated.
        let punctuationPrefix = String(resolved.prefix(while: { sentenceEndingPunctuation.contains($0) }))
        let spacingSuffix = String(resolved.dropFirst(punctuationPrefix.count))

        if sentenceEndingPunctuation.contains(trimmed.last!) {
            return trimmed + spacingSuffix
        }

        return trimmed + resolved
    }

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
        systemPrompt: String = "",
        pasteScriptOutput: Bool = false
    ) {
        self.id = id
        self.name = name
        self.actionType = actionType
        self.bashCommand = bashCommand
        self.terminatorTemplateEnabled = terminatorTemplateEnabled
        self.terminatorTemplate = terminatorTemplate
        self.systemPromptEnabled = systemPromptEnabled
        self.systemPrompt = systemPrompt
        self.pasteScriptOutput = pasteScriptOutput
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
        pasteScriptOutput = try container.decodeIfPresent(Bool.self, forKey: .pasteScriptOutput) ?? false
    }
}
