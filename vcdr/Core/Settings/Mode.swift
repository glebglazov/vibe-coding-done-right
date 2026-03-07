import Foundation

enum ProcessingType: String, Codable, CaseIterable {
    case none
    case bashScript
}

struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String

    // Processing
    var terminatorTemplateEnabled: Bool
    var terminatorTemplate: String
    var processingType: ProcessingType
    var processingCommand: String
    var systemPromptEnabled: Bool
    var systemPrompt: String

    // Output
    var defaultOutputDestinationID: UUID

    /// Whether this mode supports follow-up conversations (requires a processing script).
    var canFollowUp: Bool { processingType == .bashScript }

    // MARK: - Constants

    static let defaultTerminatorTemplate = "<dot><space>"
    private static let sentenceEndingPunctuation: Set<Character> = [".", "?", "!"]

    // MARK: - Text Pipeline

    /// Pre-processes transcription text by applying terminator, follow-up context
    /// (previous capture), system prompt (bash processing only), and appending
    /// any captured selection.
    /// This is step 1 of the pipeline — before the optional processing script.
    func applyPreProcessing(_ text: String, capturedSelection: String?, followUpContext: String? = nil) -> String {
        var result = terminatorTemplateEnabled
            ? Self.applyTerminator(text, terminator: terminatorTemplate)
            : text

        // Prepend follow-up context (previous capture result) before new dictation
        if let context = followUpContext {
            result = context + "\n\n" + result
        }

        if processingType == .bashScript && systemPromptEnabled && !systemPrompt.isEmpty {
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
        Mode(id: UUID(), name: "Default")
    }

    init(
        id: UUID,
        name: String,
        processingType: ProcessingType = .none,
        processingCommand: String = "",
        terminatorTemplateEnabled: Bool = false,
        terminatorTemplate: String = defaultTerminatorTemplate,
        systemPromptEnabled: Bool = false,
        systemPrompt: String = "",
        defaultOutputDestinationID: UUID = OutputDestination.builtInOutputPanelID
    ) {
        self.id = id
        self.name = name
        self.processingType = processingType
        self.processingCommand = processingCommand
        self.terminatorTemplateEnabled = terminatorTemplateEnabled
        self.terminatorTemplate = terminatorTemplate
        self.systemPromptEnabled = systemPromptEnabled
        self.systemPrompt = systemPrompt
        self.defaultOutputDestinationID = defaultOutputDestinationID
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, name
        case terminatorTemplateEnabled, terminatorTemplate
        case processingType, processingCommand
        case systemPromptEnabled, systemPrompt
        case defaultOutputDestinationID
        // Legacy keys (read-only, for migration)
        case actionType, bashCommand, pasteScriptOutput
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(terminatorTemplateEnabled, forKey: .terminatorTemplateEnabled)
        try container.encode(terminatorTemplate, forKey: .terminatorTemplate)
        try container.encode(processingType, forKey: .processingType)
        try container.encode(processingCommand, forKey: .processingCommand)
        try container.encode(systemPromptEnabled, forKey: .systemPromptEnabled)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(defaultOutputDestinationID, forKey: .defaultOutputDestinationID)
        // Legacy keys (actionType, bashCommand, pasteScriptOutput) are NOT written.
        // Once saved in new format, old keys are gone (one-way migration).
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        terminatorTemplateEnabled = try container.decodeIfPresent(Bool.self, forKey: .terminatorTemplateEnabled) ?? false
        terminatorTemplate = try container.decodeIfPresent(String.self, forKey: .terminatorTemplate) ?? Self.defaultTerminatorTemplate
        systemPromptEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemPromptEnabled) ?? false
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        defaultOutputDestinationID = try container.decodeIfPresent(UUID.self, forKey: .defaultOutputDestinationID) ?? OutputDestination.builtInOutputPanelID

        // New fields
        if let newProcessingType = try container.decodeIfPresent(ProcessingType.self, forKey: .processingType) {
            self.processingType = newProcessingType
            self.processingCommand = try container.decodeIfPresent(String.self, forKey: .processingCommand) ?? ""
        } else {
            // Migrate from legacy actionType + bashCommand
            let legacyActionType = try container.decodeIfPresent(PostTranscriptionActionType.self, forKey: .actionType)
            let legacyBashCommand = try container.decodeIfPresent(String.self, forKey: .bashCommand) ?? ""
            switch legacyActionType {
            case .bash:
                self.processingType = .bashScript
                self.processingCommand = legacyBashCommand
            default:
                self.processingType = .none
                self.processingCommand = ""
            }
        }
    }
}
