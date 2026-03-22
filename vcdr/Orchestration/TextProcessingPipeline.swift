import Foundation

/// Result of running the text processing pipeline, including metadata
/// about whether external processing (e.g. a bash script) was invoked.
struct PipelineResult {
    let text: String
    /// True when the pipeline executed an external command (bash script)
    /// whose stdout became the output — making this a "conversation" turn.
    let hadExternalProcessing: Bool
}

/// Result of the streaming pipeline variant.
struct StreamingPipelineResult {
    let chunks: AsyncThrowingStream<String, Error>
    let cancel: @Sendable () -> Void
    /// True when the pipeline executed an external command (bash script).
    let hadExternalProcessing: Bool
}

enum TextProcessingPipeline {
    /// Runs the text processing pipeline: pre-processing (terminator, system prompt,
    /// follow-up context, captured context) followed by optional bash script execution.
    static func run(
        mode: Mode,
        text: String,
        captures: [CapturedContext],
        followUpContext: String?,
        conversationTurns: [ConversationTurn],
        conversationID: UUID,
        parameterValues: [String: String] = [:]
    ) async throws -> PipelineResult {
        // Step 1: Pre-processing (terminator, system prompt, follow-up context, captures)
        let preprocessedText = mode.applyPreProcessing(text, captures: captures, followUpContext: followUpContext)

        // Step 2: Processing (optional bash script)
        switch mode.processingType {
        case .none:
            return PipelineResult(text: preprocessedText, hadExternalProcessing: false)
        case .bashScript:
            let conversationJSON = buildConversationMessages(
                mode: mode,
                currentText: text,
                currentCaptures: captures,
                turns: conversationTurns
            )
            let paramEnv = Dictionary(
                uniqueKeysWithValues: parameterValues.map { ("VCDR_PARAM_\($0.key)", $0.value) }
            )
            let processedText = try await BashRunner.run(
                command: mode.processingCommand,
                text: preprocessedText,
                conversationMessages: conversationJSON,
                conversationID: conversationID.uuidString,
                extraEnvironment: paramEnv
            )
            return PipelineResult(text: processedText, hadExternalProcessing: true)
        }
    }

    /// Streaming variant: returns chunks as they arrive from the bash script.
    /// For `.none` modes, returns a single-chunk stream with the preprocessed text.
    static func runStreaming(
        mode: Mode,
        text: String,
        captures: [CapturedContext],
        followUpContext: String?,
        conversationTurns: [ConversationTurn],
        conversationID: UUID,
        parameterValues: [String: String] = [:]
    ) -> StreamingPipelineResult {
        let preprocessedText = mode.applyPreProcessing(text, captures: captures, followUpContext: followUpContext)

        switch mode.processingType {
        case .none:
            let stream = AsyncThrowingStream<String, Error> { continuation in
                continuation.yield(preprocessedText)
                continuation.finish()
            }
            return StreamingPipelineResult(chunks: stream, cancel: {}, hadExternalProcessing: false)
        case .bashScript:
            let conversationJSON = buildConversationMessages(
                mode: mode,
                currentText: text,
                currentCaptures: captures,
                turns: conversationTurns
            )
            let paramEnv = Dictionary(
                uniqueKeysWithValues: parameterValues.map { ("VCDR_PARAM_\($0.key)", $0.value) }
            )
            let result = BashRunner.runStreaming(
                command: mode.processingCommand,
                text: preprocessedText,
                conversationMessages: conversationJSON,
                conversationID: conversationID.uuidString,
                extraEnvironment: paramEnv
            )
            return StreamingPipelineResult(chunks: result.stream, cancel: result.cancel, hadExternalProcessing: true)
        }
    }

    /// Builds an OpenAI/Ollama-compatible JSON messages array from conversation history.
    /// Format: `[{"role":"system","content":"..."},{"role":"user","content":"..."},{"role":"assistant","content":"..."},...]`
    private static func buildConversationMessages(
        mode: Mode,
        currentText: String,
        currentCaptures: [CapturedContext],
        turns: [ConversationTurn]
    ) -> String? {
        var messages: [[String: String]] = []

        // System prompt as first message
        if mode.systemPromptEnabled && !mode.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": mode.systemPrompt])
        }

        // Previous turns as user/assistant pairs (only include turns with mode output)
        for turn in turns where turn.output != nil {
            messages.append(["role": "user", "content": userContent(input: turn.input, captures: turn.captures)])
            messages.append(["role": "assistant", "content": turn.output!])
        }

        // Current input as the latest user message
        messages.append(["role": "user", "content": userContent(input: currentText, captures: currentCaptures)])

        guard let data = try? JSONSerialization.data(withJSONObject: messages),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Formats user message content: input first, then captured context if present.
    private static func userContent(input: String, captures: [CapturedContext]) -> String {
        guard !captures.isEmpty else { return input }
        return input + "\n\n" + Mode.formatCaptures(captures)
    }
}
