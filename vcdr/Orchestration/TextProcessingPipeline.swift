import Foundation

enum TextProcessingPipeline {
    /// Runs the text processing pipeline: pre-processing (terminator, system prompt,
    /// follow-up context, captured selection) followed by optional bash script execution.
    static func run(
        mode: Mode,
        text: String,
        capturedSelection: String?,
        followUpContext: String?,
        conversationTurns: [ConversationTurn],
        conversationID: UUID
    ) async throws -> String {
        // Step 1: Pre-processing (terminator, system prompt, follow-up context, captured selection)
        let preprocessedText = mode.applyPreProcessing(text, capturedSelection: capturedSelection, followUpContext: followUpContext)

        // Step 2: Processing (optional bash script)
        switch mode.processingType {
        case .none:
            return preprocessedText
        case .bashScript:
            let conversationJSON = buildConversationMessages(
                mode: mode,
                currentText: text,
                currentCapturedSelection: capturedSelection,
                turns: conversationTurns
            )
            return try await BashRunner.run(
                command: mode.processingCommand,
                text: preprocessedText,
                conversationMessages: conversationJSON,
                conversationID: conversationID.uuidString
            )
        }
    }

    /// Builds an OpenAI/Ollama-compatible JSON messages array from conversation history.
    /// Format: `[{"role":"system","content":"..."},{"role":"user","content":"..."},{"role":"assistant","content":"..."},...]`
    private static func buildConversationMessages(
        mode: Mode,
        currentText: String,
        currentCapturedSelection: String?,
        turns: [ConversationTurn]
    ) -> String? {
        var messages: [[String: String]] = []

        // System prompt as first message
        if mode.systemPromptEnabled && !mode.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": mode.systemPrompt])
        }

        // Previous turns as user/assistant pairs
        for turn in turns {
            messages.append(["role": "user", "content": userContent(input: turn.input, capturedSelection: turn.capturedSelection)])
            messages.append(["role": "assistant", "content": turn.output])
        }

        // Current input as the latest user message
        messages.append(["role": "user", "content": userContent(input: currentText, capturedSelection: currentCapturedSelection)])

        guard let data = try? JSONSerialization.data(withJSONObject: messages),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Formats user message content: input first, then captured selection if present.
    private static func userContent(input: String, capturedSelection: String?) -> String {
        guard let selection = capturedSelection, !selection.isEmpty else {
            return input
        }
        return input + "\n\n" + selection
    }
}
