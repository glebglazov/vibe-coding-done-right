import Foundation

enum ProcessingType: String, Codable, CaseIterable {
    case none
    case bashScript
}

struct ModeParameterOption: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var value: String
}

struct ModeParameter: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var options: [ModeParameterOption]

    /// Sanitized name for use as environment variable suffix: VCDR_PARAM_{suffix}
    var environmentVariableSuffix: String {
        name.uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .replacingOccurrences(of: " ", with: "_")
    }
}

struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isDisabled: Bool
    var templateID: String?

    // Processing
    var processingType: ProcessingType
    var processingCommand: String
    var systemPromptEnabled: Bool
    var systemPrompt: String

    // Parameters
    var parameters: [ModeParameter]

    // Output
    var defaultOutputDestinationID: UUID

    // Behavior
    var quickAction: Bool

    /// Joined labels from the first option of each parameter (the defaults, without overrides).
    /// Used in static UI contexts (settings, menu bar, quick actions) where there's no active session.
    var defaultParameterLabels: String? {
        let labels = parameters.compactMap { param -> String? in
            guard !param.options.isEmpty else { return nil }
            return param.options.first?.label
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    // MARK: - Constants

    static let defaultTerminatorTemplate = "<dot><space>"
    private static let sentenceEndingPunctuation: Set<Character> = [".", "?", "!"]

    // MARK: - Text Pipeline

    /// Pre-processes text by prepending follow-up context (previous capture),
    /// system prompt (bash processing only), and appending any captured context items.
    /// This is step 1 of the pipeline — before the optional processing script.
    func applyPreProcessing(_ text: String, captures: [CapturedContext], followUpContext: String? = nil) -> String {
        var result = text

        // Prepend follow-up context (previous capture result) before new dictation
        if let context = followUpContext {
            result = context + "\n\n" + result
        }

        if processingType == .bashScript && systemPromptEnabled && !systemPrompt.isEmpty {
            result = systemPrompt + "\n\n" + result
        }

        if !captures.isEmpty {
            result += "\n\n" + Self.formatCaptures(captures)
        }

        return result
    }

    /// Formats captures for inclusion in pipeline text using `<capture-N>` tags.
    static func formatCaptures(_ captures: [CapturedContext]) -> String {
        guard !captures.isEmpty else { return "" }
        if captures.count == 1 {
            return "<capture-1>\(captures[0].text)</capture-1>"
        }
        return captures.enumerated().map { index, capture in
            "<capture-\(index + 1)>\(capture.text)</capture-\(index + 1)>"
        }.joined(separator: "\n\n")
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
        isDisabled: Bool = false,
        templateID: String? = nil,
        processingType: ProcessingType = .none,
        processingCommand: String = "",
        systemPromptEnabled: Bool = false,
        systemPrompt: String = "",
        defaultOutputDestinationID: UUID = OutputDestination.builtInOutputPanelID,
        parameters: [ModeParameter] = [],
        quickAction: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isDisabled = isDisabled
        self.templateID = templateID
        self.processingType = processingType
        self.processingCommand = processingCommand
        self.systemPromptEnabled = systemPromptEnabled
        self.systemPrompt = systemPrompt
        self.defaultOutputDestinationID = defaultOutputDestinationID
        self.parameters = parameters
        self.quickAction = quickAction
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, name, isDisabled, templateID
        case processingType, processingCommand
        case systemPromptEnabled, systemPrompt
        case defaultOutputDestinationID
        case parameters
        case quickAction
        // Legacy keys (read-only, for migration)
        case actionType, bashCommand, pasteScriptOutput
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isDisabled, forKey: .isDisabled)
        try container.encodeIfPresent(templateID, forKey: .templateID)
        try container.encode(processingType, forKey: .processingType)
        try container.encode(processingCommand, forKey: .processingCommand)
        try container.encode(systemPromptEnabled, forKey: .systemPromptEnabled)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(defaultOutputDestinationID, forKey: .defaultOutputDestinationID)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(quickAction, forKey: .quickAction)
        // Legacy keys (actionType, bashCommand, pasteScriptOutput) are NOT written.
        // Once saved in new format, old keys are gone (one-way migration).
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        systemPromptEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemPromptEnabled) ?? false
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        defaultOutputDestinationID = try container.decodeIfPresent(UUID.self, forKey: .defaultOutputDestinationID) ?? OutputDestination.builtInOutputPanelID
        parameters = try container.decodeIfPresent([ModeParameter].self, forKey: .parameters) ?? []
        quickAction = try container.decodeIfPresent(Bool.self, forKey: .quickAction) ?? false

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
