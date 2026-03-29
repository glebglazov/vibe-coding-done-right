import Foundation
import OSLog

/// Result of running the text processing pipeline, including metadata
/// about whether external processing (e.g. a bash script or AI) was invoked.
struct PipelineResult {
    let text: String
    /// True when the pipeline executed an external command (bash script or AI processing)
    /// whose output became the result.
    let hadExternalProcessing: Bool
    /// When AI processing fails, this contains the raw text and error message
    /// so the caller can offer a preview with retry.
    let aiProcessingFallback: AIProcessingFallback?
}

struct AIProcessingFallback {
    let rawText: String
    let errorMessage: String
}

enum TextProcessingPipeline {

    /// Runs the three-stage text processing pipeline:
    /// 1. Algorithmic pre-processing — speech cleanup (filler word removal)
    /// 2. External processing — input structuring + content processing (none/AI/bash)
    /// 3. Algorithmic post-processing — output formatting (terminator)
    static func run(
        mode: Mode,
        text: String,
        captures: [CapturedContext],
        parameterValues: [String: String] = [:],
        variableEnvironment: [String: String] = [:],
        removeFillerWords: Bool = false,
        terminatorTemplateEnabled: Bool = false,
        terminatorTemplate: String = ""
    ) async throws -> PipelineResult {
        // MARK: Algorithmic pre-processing — speech cleanup
        let cleanedText = removeFillerWords ? FillerWordRemover.remove(from: text) : text

        // MARK: External processing — content processing
        let structured = structureInput(text: cleanedText, captures: captures, mode: mode)
        let result: PipelineResult

        switch mode.processingType {
        case .none:
            result = PipelineResult(text: structured, hadExternalProcessing: false, aiProcessingFallback: nil)

        case .aiProcessing:
            let apiKey = variableEnvironment[mode.aiProvider.apiKeyVariableName] ?? ""
            let systemPrompt: String = switch mode.aiPromptType {
            case .dictation: BuiltInPrompts.dictation
            case .custom: mode.systemPrompt
            }
            do {
                let processedText = try await AIClient.process(
                    text: structured,
                    systemPrompt: systemPrompt,
                    provider: mode.aiProvider,
                    apiKey: apiKey
                )
                result = PipelineResult(text: processedText, hadExternalProcessing: true, aiProcessingFallback: nil)
            } catch {
                Logger.app.warning("AI processing failed, falling back to raw text: \(error)")
                let fallbackText = structureInputPlaintext(text: cleanedText, captures: captures)
                result = PipelineResult(
                    text: fallbackText,
                    hadExternalProcessing: false,
                    aiProcessingFallback: AIProcessingFallback(rawText: cleanedText, errorMessage: error.localizedDescription)
                )
            }

        case .bashScript:
            let paramEnv = Dictionary(
                uniqueKeysWithValues: parameterValues.map { ("VCDR_PARAM_\($0.key)", $0.value) }
            )
            var combinedEnv = variableEnvironment
            combinedEnv.merge(paramEnv) { _, param in param }
            let processedText = try await BashRunner.run(
                command: mode.processingCommand,
                text: structured,
                extraEnvironment: combinedEnv
            )
            result = PipelineResult(text: processedText, hadExternalProcessing: true, aiProcessingFallback: nil)
        }

        // MARK: Algorithmic post-processing — output formatting
        let finalText = terminatorTemplateEnabled
            ? Mode.applyTerminator(result.text, terminator: terminatorTemplate)
            : result.text

        return PipelineResult(
            text: finalText,
            hadExternalProcessing: result.hadExternalProcessing,
            aiProcessingFallback: result.aiProcessingFallback
        )
    }

    // MARK: - Processing Type Input Structuring

    /// Shared interface: each processing type structures input for its consumer.
    /// Dispatches to the appropriate implementation based on processing type.
    private static func structureInput(
        text: String,
        captures: [CapturedContext],
        mode: Mode
    ) -> String {
        switch mode.processingType {
        case .none:
            return structureInputPlaintext(text: text, captures: captures)
        case .aiProcessing:
            // AI processing: XML structure WITHOUT system prompt in the text
            // (system prompt is sent as a separate API parameter)
            return structureInputXML(text: text, captures: captures, includeSystemPrompt: false, mode: mode)
        case .bashScript:
            return structureInputXML(text: text, captures: captures, includeSystemPrompt: true, mode: mode)
        }
    }

    /// Plaintext input structuring for .none — messenger-style quoted captures.
    /// Output goes directly to human-readable destinations (messengers, text fields).
    private static func structureInputPlaintext(
        text: String,
        captures: [CapturedContext]
    ) -> String {
        guard !captures.isEmpty else { return text }
        let quoted = captures.map { capture in
            capture.text.components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
        return text + "\n\n" + quoted
    }

    /// XML input structuring for .aiProcessing/.bashScript — <dictation> wrapping,
    /// optional system prompt, and XML capture tags for machine-parseable input.
    private static func structureInputXML(
        text: String,
        captures: [CapturedContext],
        includeSystemPrompt: Bool,
        mode: Mode
    ) -> String {
        var result = "<dictation>\(text)</dictation>"
        if includeSystemPrompt && mode.systemPromptEnabled && !mode.systemPrompt.isEmpty {
            result = mode.systemPrompt + "\n\n" + result
        }
        if !captures.isEmpty {
            result += "\n\n" + Mode.formatCaptures(captures)
        }
        return result
    }
}
