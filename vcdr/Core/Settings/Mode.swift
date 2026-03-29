import Foundation

enum ProcessingType: String, Codable, CaseIterable {
    case none
    case aiProcessing
    case bashScript
}

enum AIProvider: String, Codable, CaseIterable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }

    /// The variable name the user must set in Variables for this provider.
    var apiKeyVariableName: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OPENAI_API_KEY"
        }
    }
}

enum AIPromptType: String, Codable, CaseIterable {
    case dictation
    case custom

    var displayName: String {
        switch self {
        case .dictation: "AI Dictation"
        case .custom: "Custom"
        }
    }
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

    // MARK: - Option Mutation

    mutating func addOption() {
        options.append(ModeParameterOption(id: UUID(), label: "", value: ""))
    }

    mutating func removeOption(at index: Int) {
        options.remove(at: index)
    }

    mutating func moveOptionUp(at index: Int) {
        guard index > 0 else { return }
        options.swapAt(index, index - 1)
    }

    mutating func moveOptionDown(at index: Int) {
        guard index < options.count - 1 else { return }
        options.swapAt(index, index + 1)
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
    var aiProvider: AIProvider
    var aiPromptType: AIPromptType

    // Parameters
    var parameters: [ModeParameter]

    // Output
    var defaultOutputDestinationID: UUID

    // Behavior
    /// When true, shows the transcription in the panel for editing before submission.
    /// When false (default), executes the action immediately after transcription.
    var showPreview: Bool
    var saveResultToClipboard: Bool

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

    /// Formats captures for inclusion in pipeline text using `<capture id="N">` tags.
    static func formatCaptures(_ captures: [CapturedContext]) -> String {
        guard !captures.isEmpty else { return "" }
        if captures.count == 1 {
            return "<capture id=\"1\">\(captures[0].text)</capture>"
        }
        return captures.enumerated().map { index, capture in
            "<capture id=\"\(index + 1)\">\(capture.text)</capture>"
        }.joined(separator: "\n\n")
    }

    /// Appends the mode's terminator to the transcription, separating punctuation
    /// from spacing. If the text already ends with sentence-ending punctuation,
    /// only the spacing portion of the terminator is appended (e.g. `"Hello."` with
    /// terminator `<dot><space>` becomes `"Hello. "`, not `"Hello."`).
    static func applyTerminator(_ text: String, terminator: String) -> String {
        guard !terminator.isEmpty else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last else { return text }

        let resolved = terminator
            .replacingOccurrences(of: "<dot>", with: ".")
            .replacingOccurrences(of: "<space>", with: " ")
            .replacingOccurrences(of: "<newline>", with: "\n")

        // Split resolved terminator into leading punctuation and trailing spacing.
        // If text already ends with punctuation, skip the punctuation part but
        // still append spacing so consecutive dictations are properly separated.
        let punctuationPrefix = String(resolved.prefix(while: { sentenceEndingPunctuation.contains($0) }))
        let spacingSuffix = String(resolved.dropFirst(punctuationPrefix.count))

        if sentenceEndingPunctuation.contains(lastChar) {
            return trimmed + spacingSuffix
        }

        return trimmed + resolved
    }

    // MARK: - Parameter Mutation

    mutating func removeParameter(at index: Int) {
        parameters.remove(at: index)
    }

    mutating func moveParameterUp(at index: Int) {
        guard index > 0 else { return }
        parameters.swapAt(index, index - 1)
    }

    mutating func moveParameterDown(at index: Int) {
        guard index < parameters.count - 1 else { return }
        parameters.swapAt(index, index + 1)
    }

    mutating func addParameter() {
        parameters.append(
            ModeParameter(id: UUID(), name: "", options: [
                ModeParameterOption(id: UUID(), label: "", value: "")
            ])
        )
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
        aiProvider: AIProvider = .anthropic,
        aiPromptType: AIPromptType = .dictation,
        defaultOutputDestinationID: UUID = OutputDestination.builtInPasteToInitialAppID,
        parameters: [ModeParameter] = [],
        showPreview: Bool = false,
        saveResultToClipboard: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isDisabled = isDisabled
        self.templateID = templateID
        self.processingType = processingType
        self.processingCommand = processingCommand
        self.systemPromptEnabled = systemPromptEnabled
        self.systemPrompt = systemPrompt
        self.aiProvider = aiProvider
        self.aiPromptType = aiPromptType
        self.defaultOutputDestinationID = defaultOutputDestinationID
        self.parameters = parameters
        self.showPreview = showPreview
        self.saveResultToClipboard = saveResultToClipboard
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, name, isDisabled, templateID
        case processingType, processingCommand
        case systemPromptEnabled, systemPrompt
        case aiProvider, aiPromptType
        case defaultOutputDestinationID
        case parameters
        case showPreview
        case saveResultToClipboard
        // Legacy key for migration (quickAction was inverted: true = skip preview)
        case quickAction
        // Legacy keys (read-only, for migration)
        case actionType, bashCommand, pasteScriptOutput
        case companionIntegrationMode // legacy, read-only for migration
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
        try container.encode(aiProvider, forKey: .aiProvider)
        try container.encode(aiPromptType, forKey: .aiPromptType)
        try container.encode(defaultOutputDestinationID, forKey: .defaultOutputDestinationID)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(showPreview, forKey: .showPreview)
        try container.encode(saveResultToClipboard, forKey: .saveResultToClipboard)
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
        defaultOutputDestinationID = try container.decodeIfPresent(UUID.self, forKey: .defaultOutputDestinationID) ?? OutputDestination.builtInPasteToInitialAppID
        parameters = try container.decodeIfPresent([ModeParameter].self, forKey: .parameters) ?? []
        // New key takes precedence; fall back to inverted legacy quickAction
        if let preview = try container.decodeIfPresent(Bool.self, forKey: .showPreview) {
            showPreview = preview
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .quickAction) {
            // quickAction true meant "skip preview" → showPreview false
            showPreview = !legacy
        } else {
            showPreview = false
        }
        saveResultToClipboard = try container.decodeIfPresent(Bool.self, forKey: .saveResultToClipboard) ?? false

        // New fields — with companion → aiProcessing migration
        if let rawType = try container.decodeIfPresent(String.self, forKey: .processingType) {
            if rawType == "companion" {
                // Migration: companion → aiProcessing with Anthropic defaults
                self.processingType = .aiProcessing
                self.aiProvider = .anthropic
                self.aiPromptType = .dictation
            } else {
                self.processingType = ProcessingType(rawValue: rawType) ?? .none
                self.aiProvider = try container.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? .anthropic
                self.aiPromptType = try container.decodeIfPresent(AIPromptType.self, forKey: .aiPromptType) ?? .dictation
            }
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
            self.aiProvider = .anthropic
            self.aiPromptType = .dictation
        }
    }
}
