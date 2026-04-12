import Foundation
import AppKit
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
        // Cursor context for context-aware formatting
        let cursorContext: CursorContext?

        init(
            text: String,
            mode: Mode,
            captures: [CapturedContext],
            conversationID: UUID,
            parameterValues: [String: String],
            variableEnvironment: [String: String],
            destination: OutputDestination,
            targetAppPID: pid_t?,
            saveResultToClipboard: Bool,
            removeFillerWords: Bool,
            terminatorTemplateEnabled: Bool,
            terminatorTemplate: String,
            style: Style,
            cursorContext: CursorContext? = nil
        ) {
            self.text = text
            self.mode = mode
            self.captures = captures
            self.conversationID = conversationID
            self.parameterValues = parameterValues
            self.variableEnvironment = variableEnvironment
            self.destination = destination
            self.targetAppPID = targetAppPID
            self.saveResultToClipboard = saveResultToClipboard
            self.removeFillerWords = removeFillerWords
            self.terminatorTemplateEnabled = terminatorTemplateEnabled
            self.terminatorTemplate = terminatorTemplate
            self.style = style
            self.cursorContext = cursorContext
        }
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
        // Staleness check: discard context if source app no longer matches target app
        let effectiveCursorContext: CursorContext? = {
            guard let cursorContext = context.cursorContext,
                  let sourceBundleID = cursorContext.sourceBundleID,
                  let targetPID = context.targetAppPID,
                  let targetApp = NSRunningApplication(processIdentifier: targetPID) else {
                Logger.textTransform.debug("Cursor context staleness check: skipped (missing context/bundleID/targetApp)")
                return context.cursorContext
            }
            // Compare bundle IDs - if they differ, user switched apps during recording
            if sourceBundleID == targetApp.bundleIdentifier {
                Logger.textTransform.debug("Cursor context staleness check: passed (source=\(sourceBundleID))")
                return cursorContext
            } else {
                Logger.textTransform.info("Cursor context discarded: stale (source=\(sourceBundleID), target=\(targetApp.bundleIdentifier ?? "nil"))")
                return nil
            }
        }()

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
            style: context.style,
            cursorContext: effectiveCursorContext
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
