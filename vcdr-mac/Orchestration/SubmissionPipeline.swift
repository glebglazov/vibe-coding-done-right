import Foundation
import OSLog

/// Stateless pipeline executor. Handles text processing and output routing.
/// Returns results for the caller to drive UI transitions.
enum SubmissionPipeline {

    struct Context {
        let text: String
        let mode: Mode
        let captures: [CapturedContext]
        let conversationID: UUID
        let parameterValues: [String: String]
        let variableEnvironment: [String: String]
        let destination: OutputDestination
        let targetAppPID: pid_t?
        let saveResultToClipboard: Bool
        // Algorithmic processing settings
        let removeFillerWords: Bool
        let terminatorTemplateEnabled: Bool
        let terminatorTemplate: String
        // Style transformation settings
        let style: Style
    }

    struct Result {
        let processedText: String
        let hadExternalProcessing: Bool
        let aiProcessingFallback: AIProcessingFallback?
    }

    // MARK: - Non-Streaming Execution

    /// Runs the text processing pipeline (mode transforms) without executing the output action.
    static func process(
        context: Context,
        aiPort: any AIProcessingPort = AIProcessingAdapter()
    ) async throws -> Result {
        let pipelineResult = try await TextProcessingPipeline.run(
            mode: context.mode,
            text: context.text,
            captures: context.captures,
            parameterValues: context.parameterValues,
            variableEnvironment: context.variableEnvironment,
            removeFillerWords: context.removeFillerWords,
            terminatorTemplateEnabled: context.terminatorTemplateEnabled,
            terminatorTemplate: context.terminatorTemplate,
            aiPort: aiPort,
            style: context.style
        )
        return Result(
            processedText: pipelineResult.text,
            hadExternalProcessing: pipelineResult.hadExternalProcessing,
            aiProcessingFallback: pipelineResult.aiProcessingFallback
        )
    }

    /// Executes the output action (paste/copy/bash).
    static func executeAction(context: Context, processedText: String) async throws {
        if let action = OutputActionFactory.makeAction(
            for: context.destination,
            targetAppPID: context.targetAppPID,
            saveResultToClipboard: context.saveResultToClipboard,
            variableEnvironment: context.variableEnvironment
        ) {
            try await action.execute(text: processedText)
        }
    }

    // MARK: - History Recording

    static func recordHistory(
        history: TranscriptionHistory,
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        modeID: UUID,
        modeName: String
    ) {
        history.record(
            conversationID: conversationID,
            inputSegments: inputSegments,
            output: output,
            modeID: modeID,
            modeName: modeName
        )
    }
}
