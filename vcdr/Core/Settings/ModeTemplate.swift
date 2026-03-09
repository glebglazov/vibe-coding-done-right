import Foundation

struct ModeTemplate {
    let id: String
    let defaultName: String
    /// Shell command to check availability. `nil` means always available.
    let availabilityCommand: String?
    let processingType: ProcessingType
    let processingCommand: String
    let terminatorTemplateEnabled: Bool
    let systemPromptEnabled: Bool
    let systemPrompt: String
    let parameters: [ModeParameter]
    let defaultOutputDestinationID: UUID

    func makeMode() -> Mode {
        Mode(
            id: UUID(),
            name: defaultName,
            isDisabled: false,
            templateID: id,
            processingType: processingType,
            processingCommand: processingCommand,
            terminatorTemplateEnabled: terminatorTemplateEnabled,
            systemPromptEnabled: systemPromptEnabled,
            systemPrompt: systemPrompt,
            defaultOutputDestinationID: defaultOutputDestinationID,
            parameters: parameters
        )
    }

    /// Resets a mode's editable fields to template defaults, preserving id, isDisabled, and templateID.
    func resetMode(_ mode: inout Mode) {
        mode.name = defaultName
        mode.processingType = processingType
        mode.processingCommand = processingCommand
        mode.terminatorTemplateEnabled = terminatorTemplateEnabled
        mode.systemPromptEnabled = systemPromptEnabled
        mode.systemPrompt = systemPrompt
        mode.terminatorTemplate = Mode.defaultTerminatorTemplate
        mode.defaultOutputDestinationID = defaultOutputDestinationID
        mode.parameters = parameters
    }

    /// Finds the template definition for a given template ID.
    static func template(for id: String) -> ModeTemplate? {
        all.first(where: { $0.id == id })
    }
}

// MARK: - Template Definitions

extension ModeTemplate {
    // MARK: - Fixed UUIDs for template parameters

    // Claude Code parameter IDs
    private static let claudeCodeModelParamID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let claudeCodeHaikuOptionID = UUID(uuidString: "10000000-0000-0000-0000-000000000011")!
    private static let claudeCodeSonnetOptionID = UUID(uuidString: "10000000-0000-0000-0000-000000000012")!
    private static let claudeCodeOpusOptionID = UUID(uuidString: "10000000-0000-0000-0000-000000000013")!

    // Ollama parameter IDs
    private static let ollamaModelParamID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private static let ollamaQwen35_08bOptionID = UUID(uuidString: "10000000-0000-0000-0000-000000000021")!
    private static let ollamaQwen35_4bOptionID = UUID(uuidString: "10000000-0000-0000-0000-000000000022")!

    static let dictation = ModeTemplate(
        id: "dictation",
        defaultName: "Dictation",
        availabilityCommand: nil,
        processingType: .none,
        processingCommand: "",
        terminatorTemplateEnabled: true,
        systemPromptEnabled: false,
        systemPrompt: "",
        parameters: [],
        defaultOutputDestinationID: OutputDestination.builtInPasteID
    )

    static let claudeCode = ModeTemplate(
        id: "claude-code",
        defaultName: "Claude Code",
        availabilityCommand: "claude",
        processingType: .bashScript,
        processingCommand: "zsh -ic 'set -o pipefail; cd /tmp && (\n  claude -p --model $VCDR_PARAM_MODEL --output-format stream-json --verbose --include-partial-messages --resume $VCDR_CONV_ID \"$VCDR_TEXT\" 2>/dev/null | jq --unbuffered -rj \"select(.type == \\\"stream_event\\\" and .event.delta.type? == \\\"text_delta\\\") | .event.delta.text\" ||\n  claude -p --model $VCDR_PARAM_MODEL --output-format stream-json --verbose --include-partial-messages --session-id $VCDR_CONV_ID \"$VCDR_TEXT\" 2>/dev/null | jq --unbuffered -rj \"select(.type == \\\"stream_event\\\" and .event.delta.type? == \\\"text_delta\\\") | .event.delta.text\"\n)'",
        terminatorTemplateEnabled: false,
        systemPromptEnabled: true,
        systemPrompt: "Act immediately on the user's request without follow-up questions. Input is voice-dictated and may contain minor transcription errors — interpret the intent. Be concise.",
        parameters: [
            ModeParameter(id: claudeCodeModelParamID, name: "Model", options: [
                ModeParameterOption(id: claudeCodeHaikuOptionID, label: "Haiku", value: "haiku"),
                ModeParameterOption(id: claudeCodeSonnetOptionID, label: "Sonnet", value: "sonnet"),
                ModeParameterOption(id: claudeCodeOpusOptionID, label: "Opus", value: "opus"),
            ]),
        ],
        defaultOutputDestinationID: OutputDestination.builtInOutputPanelID
    )

    static let ollama = ModeTemplate(
        id: "ollama",
        defaultName: "Ollama",
        availabilityCommand: "ollama",
        processingType: .bashScript,
        processingCommand: "zsh -ic 'TERM=dumb ollama run --hidethinking --nowordwrap $VCDR_PARAM_MODEL \"$VCDR_CONVERSATION\" 2>/dev/null'",
        terminatorTemplateEnabled: false,
        systemPromptEnabled: true,
        systemPrompt: "Be concise and direct. Input is voice-dictated and may contain minor transcription errors — interpret the intent.",
        parameters: [
            ModeParameter(id: ollamaModelParamID, name: "Model", options: [
                ModeParameterOption(id: ollamaQwen35_08bOptionID, label: "Qwen3.5 - 0.8B", value: "qwen3.5:0.8b"),
                ModeParameterOption(id: ollamaQwen35_4bOptionID, label: "Qwen3.5 - 4B", value: "qwen3.5:4b"),
            ]),
        ],
        defaultOutputDestinationID: OutputDestination.builtInOutputPanelID
    )

    static let all: [ModeTemplate] = [.dictation, .claudeCode, .ollama]
}
