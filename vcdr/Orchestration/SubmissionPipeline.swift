import Foundation
import OSLog

/// Stateless pipeline executor. Handles text processing and output routing.
/// Returns results for the caller to drive UI transitions.
enum SubmissionPipeline {

    struct Context {
        let text: String
        let mode: Mode
        let captures: [CapturedContext]
        let followUpContext: String?
        let conversationTurns: [ConversationTurn]
        let conversationID: UUID
        let parameterValues: [String: String]
        let destination: OutputDestination
        let targetAppPID: pid_t?
        let saveResultToClipboard: Bool
    }

    struct Result {
        let processedText: String
        let hadExternalProcessing: Bool
    }

    // MARK: - Non-Streaming Execution

    /// Runs the text processing pipeline (mode transforms) without executing the output action.
    static func process(context: Context) async throws -> Result {
        let pipelineResult = try await TextProcessingPipeline.run(
            mode: context.mode,
            text: context.text,
            captures: context.captures,
            followUpContext: context.followUpContext,
            conversationTurns: context.conversationTurns,
            conversationID: context.conversationID,
            parameterValues: context.parameterValues
        )
        return Result(
            processedText: pipelineResult.text,
            hadExternalProcessing: pipelineResult.hadExternalProcessing
        )
    }

    /// Executes the output action (paste/copy/bash) for non-outputPanel destinations.
    static func executeAction(context: Context, processedText: String) async throws {
        guard context.destination.type != .outputPanel else { return }
        if let action = OutputActionFactory.makeAction(
            for: context.destination,
            targetAppPID: context.targetAppPID,
            conversationID: context.conversationID,
            saveResultToClipboard: context.saveResultToClipboard
        ) {
            try await action.execute(text: processedText)
        }
    }

    /// Convenience: runs processing + action in one call. Used by quick action path.
    static func run(context: Context) async throws -> Result {
        let result = try await process(context: context)
        try await executeAction(context: context, processedText: result.processedText)
        return result
    }

    // MARK: - Streaming Execution

    /// Starts a streaming pipeline. Returns the stream and metadata.
    /// Caller is responsible for consuming the stream and driving UI updates.
    static func runStreaming(context: Context) -> StreamingPipelineResult {
        TextProcessingPipeline.runStreaming(
            mode: context.mode,
            text: context.text,
            captures: context.captures,
            followUpContext: context.followUpContext,
            conversationTurns: context.conversationTurns,
            conversationID: context.conversationID,
            parameterValues: context.parameterValues
        )
    }

    // MARK: - History Recording

    static func recordTurn(
        history: TranscriptionHistory,
        conversationID: UUID,
        input: String,
        output: String,
        captures: [CapturedContext],
        modeID: UUID,
        modeName: String,
        hadExternalProcessing: Bool
    ) {
        history.recordTurn(
            conversationID: conversationID,
            input: input,
            output: output,
            captures: captures,
            modeID: modeID,
            modeName: modeName,
            hadExternalProcessing: hadExternalProcessing
        )
    }

    static func updateLastTurn(
        history: TranscriptionHistory,
        conversationID: UUID,
        input: String,
        output: String,
        captures: [CapturedContext],
        modeID: UUID,
        modeName: String,
        hadExternalProcessing: Bool
    ) {
        history.updateLastTurn(
            conversationID: conversationID,
            input: input,
            output: output,
            captures: captures,
            modeID: modeID,
            modeName: modeName,
            hadExternalProcessing: hadExternalProcessing
        )
    }
}
