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
    /// The already-structured text that was passed to the AI port on the failed attempt.
    /// The retry replays this exact string through the port so both calls share one code path.
    let structuredText: String
    let errorMessage: String
}

enum TextProcessingPipeline {

    /// Runs the three-stage text processing pipeline:
    /// 1. Algorithmic pre-processing — speech cleanup (filler word removal)
    /// 2. External processing — input structuring + content processing (none/AI/bash)
    /// 3. Style transformation — capitalization, punctuation (always applied as final step)
    /// 4. Algorithmic post-processing — output formatting (terminator)
    static func run(
        mode: Mode,
        text: String,
        captures: [CapturedContext],
        parameterValues: [String: String] = [:],
        variableEnvironment: [String: String] = [:],
        removeFillerWords: Bool = false,
        terminatorTemplateEnabled: Bool = false,
        terminatorTemplate: String = "",
        aiPort: any AIProcessingPort = AIProcessingAdapter(),
        style: Style = .casual
    ) async throws -> PipelineResult {
        // MARK: Algorithmic pre-processing — speech cleanup
        let cleanedText = removeFillerWords ? FillerWordRemover.remove(from: text) : text

        // MARK: External processing — content processing
        let structured = structureInput(text: cleanedText, captures: captures, mode: mode, style: style)
        let result: PipelineResult

        switch mode.processingType {
        case .none:
            result = PipelineResult(text: structured, hadExternalProcessing: false, aiProcessingFallback: nil)

        case .cloudAI:
            do {
                let processedText = try await aiPort.process(
                    structuredText: structured,
                    mode: mode,
                    variableEnvironment: variableEnvironment
                )
                result = PipelineResult(text: processedText, hadExternalProcessing: true, aiProcessingFallback: nil)
            } catch {
                Logger.app.warning("AI processing failed, falling back to raw text: \(error)")
                let fallbackText = structureInputPlaintext(text: cleanedText, captures: captures)
                result = PipelineResult(
                    text: fallbackText,
                    hadExternalProcessing: false,
                    aiProcessingFallback: AIProcessingFallback(
                        structuredText: structured,
                        errorMessage: error.localizedDescription
                    )
                )
            }

        case .localAgent:
            let paramEnv = Dictionary(
                uniqueKeysWithValues: parameterValues.map { ("VCDR_PARAM_\($0.key)", $0.value) }
            )
            // Only include user-defined variables if explicitly opted in, to avoid
            // passing API keys that would override the agent's subscription credentials.
            var combinedEnv = mode.localAgentPassVariables ? variableEnvironment : [:]
            combinedEnv.merge(paramEnv) { _, param in param }
            let processedText = try await BashRunner.run(
                command: mode.localAgentProvider.command,
                text: structured,
                extraEnvironment: combinedEnv
            )
            result = PipelineResult(text: processedText, hadExternalProcessing: true, aiProcessingFallback: nil)

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

        // MARK: Style transformation — capitalization, punctuation (final step before terminator)
        let styledText = StyleTransformer.transform(result.text, using: style.staticRules)

        // MARK: Algorithmic post-processing — output formatting
        let finalText = terminatorTemplateEnabled
            ? Mode.applyTerminator(styledText, terminator: terminatorTemplate)
            : styledText

        return PipelineResult(
            text: finalText,
            hadExternalProcessing: result.hadExternalProcessing,
            aiProcessingFallback: result.aiProcessingFallback
        )
    }

    // MARK: - Processing Type Input Structuring

    /// Shared interface: each processing type structures input for its consumer.
    /// Dispatches to the appropriate implementation based on processing type.
    /// For AI modes (cloudAI, localAgent), appends style.dynamicPrompt to the system prompt.
    private static func structureInput(
        text: String,
        captures: [CapturedContext],
        mode: Mode,
        style: Style
    ) -> String {
        switch mode.processingType {
        case .none:
            return structureInputPlaintext(text: text, captures: captures)
        case .cloudAI:
            // Cloud AI: XML structure WITHOUT system prompt in the text
            // (system prompt is sent as a separate API parameter)
            return structureInputXML(text: text, captures: captures, systemPrompt: nil)
        case .localAgent:
            let prompt = AIProcessingAdapter.resolvePrompt(mode)
            // Append style dynamic prompt for AI modes (macOS only)
            let promptWithStyle = AIStylePromptAppender.appendStylePrompt(to: prompt, style: style)
            return structureInputXML(text: text, captures: captures,
                                     systemPrompt: promptWithStyle.isEmpty ? nil : promptWithStyle)
        case .bashScript:
            let prompt = (mode.systemPromptEnabled && !mode.systemPrompt.isEmpty)
                ? mode.systemPrompt : nil
            return structureInputXML(text: text, captures: captures, systemPrompt: prompt)
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

    /// XML input structuring for .cloudAI/.localAgent/.bashScript — <dictation> wrapping,
    /// optional system prompt, and XML capture tags for machine-parseable input.
    private static func structureInputXML(
        text: String,
        captures: [CapturedContext],
        systemPrompt: String?
    ) -> String {
        var result = "<dictation>\(text)</dictation>"
        if let prompt = systemPrompt, !prompt.isEmpty {
            result = prompt + "\n\n" + result
        }
        if !captures.isEmpty {
            result += "\n\n" + Mode.formatCaptures(captures)
        }
        return result
    }
}
