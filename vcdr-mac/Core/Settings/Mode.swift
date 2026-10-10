import Foundation

enum ProcessingType: String, Codable, CaseIterable {
    case none
    case cloudAI
    case localAgent
    case bashScript
}

typealias AIProvider = CloudAIBackend

enum PromptType: String, Codable, CaseIterable {
    case dictation
    case assistant
    case custom

    var displayName: String {
        switch self {
        case .dictation: "Dictation"
        case .assistant: "Assistant"
        case .custom: "Custom"
        }
    }

    /// Only Dictation rewrites what was said, so only it is told each Note.
    /// Assistant writes new text and would use a Note as material, and the app
    /// cannot tell what a Custom prompt does (ADR-0026).
    var hintDetail: SpellingHints.Detail {
        switch self {
        case .dictation: .withNotes
        case .assistant, .custom: .spellingsOnly
        }
    }
}

enum LocalAgentProvider: String, Codable, CaseIterable {
    case claudeCode

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        }
    }

    /// Shell command to check availability.
    var availabilityCommand: String {
        switch self {
        case .claudeCode: "claude"
        }
    }

    /// The CLI command template. Uses $VCDR_TEXT and $VCDR_PARAM_* env vars.
    var command: String {
        switch self {
        case .claudeCode:
            "zsh -ic 'set -o pipefail; cd /tmp && claude -p --model $VCDR_PARAM_MODEL --output-format stream-json --verbose --include-partial-messages \"$VCDR_TEXT\" 2>/dev/null | jq --unbuffered -rj \"select(.type == \\\"stream_event\\\" and .event.delta.type? == \\\"text_delta\\\") | .event.delta.text\"'"
        }
    }

    /// Default parameters for this provider. Used to auto-populate user-created modes.
    var defaultParameters: [ModeParameter] {
        switch self {
        case .claudeCode:
            [ModeParameter(id: UUID(), name: "Model", options: [
                ModeParameterOption(id: UUID(), label: "Haiku", value: "haiku"),
                ModeParameterOption(id: UUID(), label: "Sonnet", value: "sonnet"),
                ModeParameterOption(id: UUID(), label: "Opus", value: "opus"),
            ])]
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
    var promptType: PromptType

    // Local Agent
    var localAgentProvider: LocalAgentProvider
    var localAgentPassVariables: Bool

    // Parameters
    private var bashScriptParameters: [ModeParameter]
    private var localAgentParameters: [ModeParameter]

    var parameters: [ModeParameter] {
        get {
            switch processingType {
            case .none, .cloudAI: []
            case .localAgent: localAgentParameters
            case .bashScript: bashScriptParameters
            }
        }
        set {
            switch processingType {
            case .none, .cloudAI: break
            case .localAgent: localAgentParameters = newValue
            case .bashScript: bashScriptParameters = newValue
            }
        }
    }

    // Transcription
    /// Which Transcription Model this Mode records with, and what it tells it.
    /// A Mode that pins nothing transcribes with the Default Transcription
    /// Model and that model's own settings — transcription is a step of the
    /// Capture Session one stage before processing, so it is an override here
    /// rather than a field the Mode always carries (`docs/adr/0016`).
    var transcriptionOverride: TranscriptionOverride

    // Output
    var defaultOutputDestinationID: UUID

    // Behavior
    /// When true, shows the transcription in the panel for editing before submission.
    /// When false (default), executes the action immediately after transcription.
    var showPreview: Bool
    var saveResultToClipboard: Bool
    /// When true, style transformations (capitalization, punctuation, dynamic prompts)
    /// are applied to the output. Dictation modes typically enable this; assistant modes disable it.
    var appliesStyles: Bool
    /// When true, cursor context (text before/after the cursor) is used for context-aware
    /// formatting: separator insertion, leading-edge capitalization, and AI context XML.
    var contextAware: Bool
    private var chosenCaptureUse: CaptureUse

    var capturePolicy: CapturePolicy {
        templateID.flatMap(ModeTemplate.template(for:))?.capturePolicy ?? .editable(default: .sentAsInput)
    }

    var captureUse: CaptureUse {
        get { capturePolicy.captureUse(choosing: chosenCaptureUse) }
        set { chosenCaptureUse = newValue }
    }

    var usesCaptures: Bool { captureUse != .ignored }

    /// Joined labels from the first option of each parameter (the defaults, without overrides).
    /// Used in static UI contexts (settings, menu bar, quick actions) where there's no active session.
    var defaultParameterLabels: String? {
        let labels = parameters.compactMap { param -> String? in
            guard !param.options.isEmpty else { return nil }
            return param.options.first?.label
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

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

    // MARK: - Parameter Mutation

    mutating func resetParameters(to defaults: [ModeParameter]) {
        bashScriptParameters = processingType == .bashScript ? defaults : []
        localAgentParameters = processingType == .localAgent && !defaults.isEmpty
            ? defaults : localAgentProvider.defaultParameters
    }

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
        promptType: PromptType = .dictation,
        localAgentProvider: LocalAgentProvider = .claudeCode,
        localAgentPassVariables: Bool = false,
        defaultOutputDestinationID: UUID = OutputDestination.builtInPasteID,
        parameters: [ModeParameter] = [],
        transcriptionOverride: TranscriptionOverride = .none,
        showPreview: Bool = false,
        saveResultToClipboard: Bool = false,
        appliesStyles: Bool = true,
        contextAware: Bool = false,
        chosenCaptureUse: CaptureUse = .sentAsInput
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
        self.promptType = promptType
        self.localAgentProvider = localAgentProvider
        self.localAgentPassVariables = localAgentPassVariables
        self.defaultOutputDestinationID = defaultOutputDestinationID
        self.bashScriptParameters = processingType == .bashScript ? parameters : []
        self.localAgentParameters = processingType == .localAgent && !parameters.isEmpty
            ? parameters : localAgentProvider.defaultParameters
        self.transcriptionOverride = transcriptionOverride
        self.showPreview = showPreview
        self.saveResultToClipboard = saveResultToClipboard
        self.appliesStyles = appliesStyles
        self.contextAware = contextAware
        self.chosenCaptureUse = chosenCaptureUse
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, name, isDisabled, templateID
        case processingType, processingCommand
        case systemPromptEnabled, systemPrompt
        case aiProvider, promptType
        case localAgentProvider, localAgentPassVariables
        // Legacy keys (read-only, for migration)
        case aiPromptType, localAgentPromptType, localAgentSystemPrompt
        case defaultOutputDestinationID
        case parameters, bashScriptParameters, localAgentParameters
        case transcriptionOverride
        case showPreview
        case saveResultToClipboard
        case appliesStyles
        case contextAware
        case captureUse
        // Legacy key for migration (quickAction was inverted: true = skip preview)
        case quickAction
        // Legacy keys (read-only, for migration)
        case actionType, bashCommand, pasteScriptOutput, appendCapturesToOutput
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
        try container.encode(promptType, forKey: .promptType)
        try container.encode(localAgentProvider, forKey: .localAgentProvider)
        try container.encode(localAgentPassVariables, forKey: .localAgentPassVariables)
        try container.encode(defaultOutputDestinationID, forKey: .defaultOutputDestinationID)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(bashScriptParameters, forKey: .bashScriptParameters)
        try container.encode(localAgentParameters, forKey: .localAgentParameters)
        try container.encode(transcriptionOverride, forKey: .transcriptionOverride)
        try container.encode(showPreview, forKey: .showPreview)
        try container.encode(saveResultToClipboard, forKey: .saveResultToClipboard)
        try container.encode(appliesStyles, forKey: .appliesStyles)
        try container.encode(contextAware, forKey: .contextAware)
        try container.encode(chosenCaptureUse, forKey: .captureUse)
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
        defaultOutputDestinationID = try container.decodeIfPresent(UUID.self, forKey: .defaultOutputDestinationID) ?? OutputDestination.builtInPasteID
        // A Mode written before Modes could pin a model overrides nothing, and
        // so records with the Default.
        transcriptionOverride = try container.decodeIfPresent(
            TranscriptionOverride.self, forKey: .transcriptionOverride
        ) ?? .none
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
        appliesStyles = try container.decodeIfPresent(Bool.self, forKey: .appliesStyles) ?? true
        contextAware = try container.decodeIfPresent(Bool.self, forKey: .contextAware) ?? false
        if let rawUse = try container.decodeIfPresent(String.self, forKey: .captureUse) {
            chosenCaptureUse = CaptureUse(rawValue: rawUse) ?? .sentAsInput
        } else {
            let appended = try container.decodeIfPresent(Bool.self, forKey: .appendCapturesToOutput) ?? false
            chosenCaptureUse = appended ? .appendedToOutput : .sentAsInput
        }

        // New fields — with companion/aiProcessing → cloudAI migration
        if let rawType = try container.decodeIfPresent(String.self, forKey: .processingType) {
            if rawType == "companion" || rawType == "aiProcessing" {
                // Migration: companion/aiProcessing → cloudAI with Anthropic defaults
                self.processingType = .cloudAI
                self.aiProvider = try container.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? .anthropic
            } else {
                self.processingType = ProcessingType(rawValue: rawType) ?? .none
                self.aiProvider = try container.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? .anthropic
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
        }

        // Local agent fields — backward-compatible defaults
        localAgentProvider = try container.decodeIfPresent(LocalAgentProvider.self, forKey: .localAgentProvider) ?? .claudeCode
        localAgentPassVariables = try container.decodeIfPresent(Bool.self, forKey: .localAgentPassVariables) ?? false

        let legacyParameters = try container.decodeIfPresent([ModeParameter].self, forKey: .parameters) ?? []
        bashScriptParameters = try container.decodeIfPresent([ModeParameter].self, forKey: .bashScriptParameters)
            ?? (processingType == .bashScript ? legacyParameters : [])
        let savedLocalParameters = try container.decodeIfPresent([ModeParameter].self, forKey: .localAgentParameters)
            ?? (processingType == .localAgent ? legacyParameters : [])
        localAgentParameters = savedLocalParameters.isEmpty
            ? localAgentProvider.defaultParameters : savedLocalParameters

        // Unified prompt type (new key takes precedence over legacy)
        if let rawPromptType = try container.decodeIfPresent(String.self, forKey: .promptType) {
            self.promptType = PromptType(rawValue: rawPromptType) ?? .dictation
        } else if self.processingType == .localAgent {
            // Legacy local agent migration
            let oldLocalType = try container.decodeIfPresent(String.self, forKey: .localAgentPromptType) ?? "default"
            if oldLocalType == "custom" {
                self.promptType = .custom
                // Migrate custom prompt text to the shared systemPrompt field
                let legacyPrompt = try container.decodeIfPresent(String.self, forKey: .localAgentSystemPrompt) ?? ""
                if !legacyPrompt.isEmpty { self.systemPrompt = legacyPrompt }
            } else {
                self.promptType = .assistant
            }
        } else {
            // Legacy Cloud AI migration: "dictation" and "custom" raw values match PromptType
            let oldAIType = try container.decodeIfPresent(String.self, forKey: .aiPromptType) ?? "dictation"
            self.promptType = PromptType(rawValue: oldAIType) ?? .dictation
        }
    }
}
