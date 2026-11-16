import Foundation
import AppKit
import OSLog

// MARK: - Input

/// Immutable snapshot from CaptureSession. Everything the processor needs
/// to run the pipeline. CaptureSession constructs this from its RunState.
struct TranscriptionInput: Sendable {
    let text: String
    let mode: Mode
    let conversationID: UUID
    let destination: OutputDestination
    let targetAppPID: pid_t?
    let cursorContext: CursorContext?
    let parameterValues: [String: String]
    let variableEnvironment: [String: String]
    /// The AI Provider's key for `mode` as the Secret Store answered — the source of
    /// truth for AI calls, and the reason an unreadable Store never reads as unset.
    let aiAPIKey: ProviderAPIKey
    let inputSegments: [InputSegment]
    let hadDestinationOverride: Bool
    let removeFillerWords: Bool
    let style: Style
    let saveResultToClipboard: Bool
    /// The Dictionary: substituted into the dictated transcript as the pipeline's
    /// first step, and every entry is a Spelling Hint for an LLM call. Defaults to
    /// empty so existing call sites that predate Substitutions compile unchanged.
    let substitutions: [Substitution]

    init(
        text: String,
        mode: Mode,
        conversationID: UUID,
        destination: OutputDestination,
        targetAppPID: pid_t?,
        cursorContext: CursorContext?,
        parameterValues: [String: String],
        variableEnvironment: [String: String],
        aiAPIKey: ProviderAPIKey = .stored(""),
        inputSegments: [InputSegment],
        hadDestinationOverride: Bool,
        removeFillerWords: Bool,
        style: Style,
        saveResultToClipboard: Bool,
        substitutions: [Substitution] = []
    ) {
        self.text = text
        self.mode = mode
        self.conversationID = conversationID
        self.destination = destination
        self.targetAppPID = targetAppPID
        self.cursorContext = cursorContext
        self.parameterValues = parameterValues
        self.variableEnvironment = variableEnvironment
        self.aiAPIKey = aiAPIKey
        self.inputSegments = inputSegments
        self.hadDestinationOverride = hadDestinationOverride
        self.removeFillerWords = removeFillerWords
        self.style = style
        self.saveResultToClipboard = saveResultToClipboard
        self.substitutions = substitutions
    }
}

// MARK: - Output

/// What the processor decided. Tells CaptureSession what UI transition to make.
enum ProcessingDisposition {
    /// Pipeline succeeded, action executed. Caller dismisses UI.
    case execute(ProcessedResult)
    /// Pipeline produced text requiring user confirmation.
    /// `handle.aiErrorMessage != nil` means AI failed and retry is available.
    case preview(PreviewHandle)
    /// No speech detected.
    case empty
}

struct ProcessedResult {
    let text: String
    let destinationName: String
}

/// Opaque handle stored by the caller. Contains everything needed for
/// confirm/retry/history without the caller knowing internals.
@MainActor
final class PreviewHandle {
    let displayText: String
    let modeName: String?
    let aiErrorMessage: String?

    // Internal state — accessed by TextProcessor and CaptureSession (same module).
    let input: TranscriptionInput
    let hadExternalProcessing: Bool
    let aiRetryStructuredText: String?

    init(
        displayText: String,
        modeName: String?,
        aiErrorMessage: String?,
        input: TranscriptionInput,
        hadExternalProcessing: Bool,
        aiRetryStructuredText: String?
    ) {
        self.displayText = displayText
        self.modeName = modeName
        self.aiErrorMessage = aiErrorMessage
        self.input = input
        self.hadExternalProcessing = hadExternalProcessing
        self.aiRetryStructuredText = aiRetryStructuredText
    }
}

// MARK: - TextProcessor

/// Deep module owning the full text processing pipeline:
/// filler removal → structuring → external processing → style transform → terminator → action execution.
///
/// Eliminates the retry-path drift risk: both `process()` and `retryAI()` apply
/// style transform + terminator through one shared internal method.
@MainActor
final class TextProcessor {

    // MARK: - Dependencies

    private let ai: any AIProcessingPort
    private let history: any HistoryStore
    private let settings: AppSettings
    private let overrides: SessionOverrides
    private var styleProvider: @MainActor @Sendable () -> Style

    init(
        aiPort: any AIProcessingPort,
        history: any HistoryStore,
        settings: AppSettings,
        overrides: SessionOverrides,
        styleProvider: @MainActor @Sendable @escaping () -> Style
    ) {
        self.ai = aiPort
        self.history = history
        self.settings = settings
        self.overrides = overrides
        self.styleProvider = styleProvider
    }

    /// Updates the style provider after initialization (breaks init circularity).
    func setStyleProvider(_ provider: @MainActor @Sendable @escaping () -> Style) {
        self.styleProvider = provider
    }

    // MARK: - Primary Entry Point

    /// Runs the full pipeline and returns a disposition.
    func process(_ input: TranscriptionInput) async throws -> ProcessingDisposition {
        guard !input.text.isEmpty else { return .empty }

        let context = makeContext(from: input)
        let pipelineResult = try await SubmissionPipeline.process(
            context: context,
            aiPort: ai
        )

        // AI processing failed — return preview with fallback text and retry info.
        if let fallback = pipelineResult.aiProcessingFallback {
            let handle = PreviewHandle(
                displayText: pipelineResult.processedText,
                modeName: nil,
                aiErrorMessage: fallback.errorMessage,
                input: input,
                hadExternalProcessing: false,
                aiRetryStructuredText: fallback.structuredText
            )
            return .preview(handle)
        }

        // Check preview rule.
        let shouldPreview = input.mode.showPreview && !input.hadDestinationOverride
        if shouldPreview {
            let handle = PreviewHandle(
                displayText: pipelineResult.processedText,
                modeName: pipelineResult.hadExternalProcessing ? input.mode.name : nil,
                aiErrorMessage: nil,
                input: input,
                hadExternalProcessing: pipelineResult.hadExternalProcessing,
                aiRetryStructuredText: nil
            )
            return .preview(handle)
        }

        // No preview — execute action immediately.
        try await executeAction(context: context, processedText: pipelineResult.processedText)
        recordHistory(
            input: input,
            processedText: pipelineResult.processedText,
            hadExternalProcessing: pipelineResult.hadExternalProcessing
        )
        overrides.clearAll()
        return .execute(ProcessedResult(
            text: pipelineResult.processedText,
            destinationName: input.destination.name.lowercased()
        ))
    }

    // MARK: - Preview Confirmation

    /// Executes a previously-previewed action, optionally with an overridden destination.
    func confirm(_ handle: PreviewHandle, destinationOverride: UUID? = nil) async throws {
        let effectiveInput: TranscriptionInput
        if let overrideID = destinationOverride {
            overrides.destinationOverride = overrideID
            let dest = settings.outputDestination(for: overrideID)
            effectiveInput = handle.input.withDestination(dest)
        } else {
            effectiveInput = handle.input
        }

        let context = makeContext(from: effectiveInput)
        try await executeAction(context: context, processedText: handle.displayText)
        recordHistory(
            input: effectiveInput,
            processedText: handle.displayText,
            hadExternalProcessing: handle.hadExternalProcessing
        )
        overrides.clearAll()
    }

    // MARK: - AI Retry

    /// Retries the failed AI call using the exact structured text from the
    /// original attempt, then applies style transform + terminator through
    /// the same code path as `process()`.
    func retryAI(_ handle: PreviewHandle) async throws -> ProcessingDisposition {
        guard let structured = handle.aiRetryStructuredText else {
            return .preview(handle)
        }

        do {
            var processedText = try await ai.process(
                structuredText: structured,
                mode: handle.input.mode,
                spellingHints: SpellingHints(handle.input.substitutions),
                apiKey: try handle.input.aiAPIKey.resolved(for: handle.input.mode.aiProvider),
                parameterValues: handle.input.parameterValues
            )

            // Apply the same post-processing as the initial pipeline path.
            let effectiveContext = handle.input.mode.contextAware ? handle.input.cursorContext : nil
            processedText = applyPostProcessing(
                processedText,
                style: handle.input.style,
                cursorContext: effectiveContext
            )

            let newHandle = PreviewHandle(
                displayText: processedText,
                modeName: handle.input.mode.name,
                aiErrorMessage: nil,
                input: handle.input,
                hadExternalProcessing: true,
                aiRetryStructuredText: nil
            )
            return .preview(newHandle)
        } catch {
            let newHandle = PreviewHandle(
                displayText: handle.displayText,
                modeName: handle.modeName,
                aiErrorMessage: error.localizedDescription,
                input: handle.input,
                hadExternalProcessing: handle.hadExternalProcessing,
                aiRetryStructuredText: structured
            )
            return .preview(newHandle)
        }
    }

    // MARK: - History for Dismissed Preview

    /// Records history for a preview dismissed without confirmation.
    func recordDismissedPreview(_ handle: PreviewHandle) {
        recordHistory(
            input: handle.input,
            processedText: handle.displayText,
            hadExternalProcessing: handle.hadExternalProcessing
        )
    }

    // MARK: - Internals

    /// Shared post-processing: style transform.
    /// Used by both the initial pipeline (via TextProcessingPipeline) and the retry path.
    private func applyPostProcessing(
        _ text: String,
        style: Style,
        cursorContext: CursorContext?
    ) -> String {
        StyleTransformer.transform(text, using: style.staticRules, cursorContext: cursorContext)
    }

    private func makeContext(from input: TranscriptionInput) -> SubmissionPipeline.Context {
        SubmissionPipeline.Context(
            text: input.text,
            mode: input.mode,
            substitutions: input.substitutions,
            conversationID: input.conversationID,
            parameterValues: input.parameterValues,
            variableEnvironment: input.variableEnvironment,
            aiAPIKey: input.aiAPIKey,
            destination: input.destination,
            targetAppPID: input.targetAppPID,
            saveResultToClipboard: input.saveResultToClipboard,
            removeFillerWords: input.removeFillerWords,
            style: input.style,
            cursorContext: input.cursorContext
        )
    }

    private func executeAction(context: SubmissionPipeline.Context, processedText: String) async throws {
        try await SubmissionPipeline.executeAction(context: context, processedText: processedText)
    }

    private func recordHistory(
        input: TranscriptionInput,
        processedText: String,
        hadExternalProcessing: Bool
    ) {
        let output = hadExternalProcessing ? processedText : nil
        history.record(
            conversationID: input.conversationID,
            inputSegments: input.inputSegments,
            output: output,
            label: input.mode.name
        )
    }
}

// MARK: - TranscriptionInput Helpers

extension TranscriptionInput {
    /// Returns a copy with a different destination (for destination override on confirm).
    func withDestination(_ destination: OutputDestination) -> TranscriptionInput {
        TranscriptionInput(
            text: text,
            mode: mode,
            conversationID: conversationID,
            destination: destination,
            targetAppPID: targetAppPID,
            cursorContext: cursorContext,
            parameterValues: parameterValues,
            variableEnvironment: variableEnvironment,
            aiAPIKey: aiAPIKey,
            inputSegments: inputSegments,
            hadDestinationOverride: hadDestinationOverride,
            removeFillerWords: removeFillerWords,
            style: style,
            saveResultToClipboard: saveResultToClipboard,
            substitutions: substitutions
        )
    }
}
