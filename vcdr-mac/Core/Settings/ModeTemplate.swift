import Foundation

struct ModeTemplate {
    let id: String
    let defaultName: String
    /// Names this template gave its Mode before `defaultName`. A saved Mode
    /// that still carries one of them was never renamed by the user.
    let earlierDefaultNames: Set<String>
    let processingType: ProcessingType
    let processingCommand: String
    let systemPromptEnabled: Bool
    let systemPrompt: String
    let aiProvider: AIProvider
    let promptType: PromptType
    let localAgentProvider: LocalAgentProvider
    let localAgentPassVariables: Bool
    let parameters: [ModeParameter]
    let defaultOutputDestinationID: UUID
    let showPreview: Bool
    let appliesStyles: Bool
    let contextAware: Bool
    let capturePolicy: CapturePolicy

    func makeMode() -> Mode {
        Mode(
            id: UUID(),
            name: defaultName,
            isDisabled: false,
            templateID: id,
            processingType: processingType,
            processingCommand: processingCommand,
            systemPromptEnabled: systemPromptEnabled,
            systemPrompt: systemPrompt,
            aiProvider: aiProvider,
            promptType: promptType,
            localAgentProvider: localAgentProvider,
            localAgentPassVariables: localAgentPassVariables,
            defaultOutputDestinationID: defaultOutputDestinationID,
            parameters: parameters,
            showPreview: showPreview,
            appliesStyles: appliesStyles,
            contextAware: contextAware,
            chosenCaptureUse: capturePolicy.initialUse
        )
    }

    /// Resets a mode's editable fields to template defaults, preserving id, isDisabled, and templateID.
    func resetMode(_ mode: inout Mode) {
        mode.name = defaultName
        mode.processingType = processingType
        mode.processingCommand = processingCommand
        mode.systemPromptEnabled = systemPromptEnabled
        mode.systemPrompt = systemPrompt
        mode.aiProvider = aiProvider
        mode.promptType = promptType
        mode.localAgentProvider = localAgentProvider
        mode.localAgentPassVariables = localAgentPassVariables
        mode.defaultOutputDestinationID = defaultOutputDestinationID
        mode.resetParameters(to: parameters)
        mode.showPreview = showPreview
        mode.appliesStyles = appliesStyles
        mode.contextAware = contextAware
        mode.captureUse = capturePolicy.initialUse
    }

    static let legacyTemplateIDs: [String: String] = ["dictation": "plain"]

    static func template(for id: String) -> ModeTemplate? {
        let currentID = legacyTemplateIDs[id] ?? id
        return all.first(where: { $0.id == currentID })
    }
}

// MARK: - Template Definitions

extension ModeTemplate {
    static let plain = ModeTemplate(
        id: "plain",
        defaultName: "AI off",
        earlierDefaultNames: ["Dictation", "Plain", "Transcription", "Verbatim"],
        processingType: .none,
        processingCommand: "",
        systemPromptEnabled: false,
        systemPrompt: "",
        aiProvider: .anthropic,
        promptType: .dictation,
        localAgentProvider: .claudeCode,
        localAgentPassVariables: false,
        parameters: [],
        defaultOutputDestinationID: OutputDestination.builtInPasteID,
        showPreview: false,
        appliesStyles: true,
        contextAware: false,
        capturePolicy: .fixed(.ignored)
    )

    static let aiDictation = ModeTemplate(
        id: "ai-dictation",
        defaultName: "AI on",
        earlierDefaultNames: ["Dictation"],
        processingType: .cloudAI,
        processingCommand: "",
        systemPromptEnabled: false,
        systemPrompt: "",
        aiProvider: .anthropic,
        promptType: .dictation,
        localAgentProvider: .claudeCode,
        localAgentPassVariables: false,
        parameters: [],
        defaultOutputDestinationID: OutputDestination.builtInPasteID,
        showPreview: false,
        appliesStyles: true,
        contextAware: false,
        capturePolicy: .fixed(.ignored)
    )

    static let all: [ModeTemplate] = [.plain, .aiDictation]
}
