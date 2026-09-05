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
        /// Substitutions applied to the dictated transcript as the pipeline's first step.
        let substitutions: [Substitution]
        let conversationID: UUID
        let parameterValues: [String: String]
        let variableEnvironment: [String: String]
        /// The AI Provider's stored API key for `mode` — the source of truth for AI calls.
        let aiAPIKey: ProviderAPIKey
        let destination: OutputDestination
        let targetAppPID: pid_t?
        let saveResultToClipboard: Bool
        // Algorithmic processing settings
        let removeFillerWords: Bool
        // Style transformation settings
        let style: Style
        // Cursor context for context-aware formatting
        let cursorContext: CursorContext?

        init(
            text: String,
            mode: Mode,
            captures: [CapturedContext],
            substitutions: [Substitution] = [],
            conversationID: UUID,
            parameterValues: [String: String],
            variableEnvironment: [String: String],
            aiAPIKey: ProviderAPIKey = .stored(""),
            destination: OutputDestination,
            targetAppPID: pid_t?,
            saveResultToClipboard: Bool,
            removeFillerWords: Bool,
            style: Style,
            cursorContext: CursorContext? = nil
        ) {
            self.text = text
            self.mode = mode
            self.captures = captures
            self.substitutions = substitutions
            self.conversationID = conversationID
            self.parameterValues = parameterValues
            self.variableEnvironment = variableEnvironment
            self.aiAPIKey = aiAPIKey
            self.destination = destination
            self.targetAppPID = targetAppPID
            self.saveResultToClipboard = saveResultToClipboard
            self.removeFillerWords = removeFillerWords
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
        // Context-aware gate: discard context if mode doesn't use it
        // Staleness check: discard context if source app no longer matches target app
        let effectiveCursorContext: CursorContext? = {
            guard context.mode.contextAware else {
                Logger.textTransform.debug("Cursor context: disabled (mode.contextAware=false)")
                return nil
            }
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
            substitutions: context.substitutions,
            parameterValues: context.parameterValues,
            variableEnvironment: context.variableEnvironment,
            aiAPIKey: context.aiAPIKey,
            removeFillerWords: context.removeFillerWords,
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
        history: any HistoryStore,
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        label: String?
    ) {
        history.record(
            conversationID: conversationID,
            inputSegments: inputSegments,
            output: output,
            label: label
        )
    }
}
