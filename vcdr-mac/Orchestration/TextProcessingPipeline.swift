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
    /// 0. Substitution — swap Trigger Phrases for Replacements in the dictated
    ///    transcript (runs first, in all modes, on the transcript only)
    /// 1. Algorithmic pre-processing — speech cleanup (filler word removal)
    /// 2. External processing — input structuring + content processing (none/AI/bash)
    /// 3. Style transformation — capitalization, punctuation (always applied as final step)
    /// 4. Algorithmic post-processing — output formatting (terminator)
    static func run(
        mode: Mode,
        text: String,
        substitutions: [Substitution] = [],
        parameterValues: [String: String] = [:],
        variableEnvironment: [String: String] = [:],
        aiAPIKey: ProviderAPIKey = .stored(""),
        removeFillerWords: Bool = false,
        aiPort: any AIProcessingPort = AIProcessingAdapter(),
        style: Style = .casual,
        cursorContext: CursorContext? = nil
    ) async throws -> PipelineResult {
        Logger.textTransform.info("Pipeline input: \"\(text)\"")

        // MARK: Substitution — first pass, all modes, dictated transcript only.
        let substitutedText = SubstitutionMatcher(substitutions: substitutions).apply(to: text)
        if substitutedText != text {
            Logger.textTransform.info("After substitutions: \"\(substitutedText)\"")
        }

        // MARK: Algorithmic pre-processing — speech cleanup
        let cleanedText = removeFillerWords ? FillerWordRemover.remove(from: substitutedText) : substitutedText

        if removeFillerWords && cleanedText != substitutedText {
            Logger.textTransform.info("After filler removal: \"\(cleanedText)\"")
        }
        if let ctx = cursorContext {
            Logger.textTransform.info("Cursor context — before: \"\(ctx.beforeText ?? "<nil>")\", after: \"\(ctx.afterText ?? "<nil>")\"")
        } else {
            Logger.textTransform.info("Cursor context: nil")
        }

        // MARK: External processing — content processing
        let spellingHints = SpellingHints(substitutions)
        let structured = structureInput(
            text: cleanedText,
            mode: mode,
            cursorContext: cursorContext
        )
        Logger.textTransform.debug("Structured input for \(mode.processingType.rawValue):\n\(structured)")
        let result: PipelineResult

        switch mode.processingType {
        case .none:
            Logger.textTransform.debug("Processing type: none (passthrough)")
            result = PipelineResult(text: structured, hadExternalProcessing: false, aiProcessingFallback: nil)

        case .cloudAI:
            do {
                let processedText = try await aiPort.process(
                    structuredText: structured,
                    mode: mode,
                    spellingHints: spellingHints,
                    apiKey: try aiAPIKey.resolved(for: mode.aiProvider),
                    parameterValues: parameterValues
                )
                Logger.textTransform.info("AI output: \"\(processedText)\"")
                result = PipelineResult(text: processedText, hadExternalProcessing: true, aiProcessingFallback: nil)
            } catch {
                Logger.app.warning("AI processing failed, falling back to raw text: \(error)")
                result = PipelineResult(
                    text: cleanedText,
                    hadExternalProcessing: false,
                    aiProcessingFallback: AIProcessingFallback(
                        structuredText: structured,
                        errorMessage: error.localizedDescription
                    )
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
            Logger.textTransform.info("Bash script output: \"\(processedText)\"")
            result = PipelineResult(text: processedText, hadExternalProcessing: true, aiProcessingFallback: nil)
        }

        // MARK: Style transformation — capitalization, punctuation (final step before terminator)
        let styledText = StyleTransformer.transform(result.text, using: style.staticRules, cursorContext: cursorContext)
        if styledText != result.text {
            Logger.textTransform.info("After style transform: \"\(styledText)\"")
        } else {
            Logger.textTransform.debug("Style transform: no change")
        }

        Logger.textTransform.info("Pipeline final output: \"\(styledText)\"")

        return PipelineResult(
            text: styledText,
            hadExternalProcessing: result.hadExternalProcessing,
            aiProcessingFallback: result.aiProcessingFallback
        )
    }

    // MARK: - Processing Type Input Structuring

    /// Shared interface: each processing type structures input for its consumer.
    /// Dispatches to the appropriate implementation based on processing type.
    /// A Bash Script gets no Spelling Hints: it is not known to call an LLM.
    private static func structureInput(
        text: String,
        mode: Mode,
        cursorContext: CursorContext?
    ) -> String {
        switch mode.processingType {
        case .none:
            return text
        case .cloudAI:
            // Cloud AI: XML structure WITHOUT system prompt in the text
            // (system prompt is sent as a separate API parameter)
            return structureInputXML(text: text, systemPrompt: nil, cursorContext: cursorContext)
        case .bashScript:
            let prompt = (mode.systemPromptEnabled && !mode.systemPrompt.isEmpty)
                ? mode.systemPrompt : nil
            return structureInputXML(text: text, systemPrompt: prompt, cursorContext: cursorContext)
        }
    }

    /// XML input structuring for .cloudAI/.bashScript — <dictation> wrapping,
    /// optional system prompt and cursor context.
    private static func structureInputXML(
        text: String,
        systemPrompt: String?,
        cursorContext: CursorContext?
    ) -> String {
        var result = ""

        // Add cursor context if available
        if let context = cursorContext,
           context.beforeText != nil || context.afterText != nil {
            result += formatCursorContextXML(context)
            result += "\n"
        }

        result += "<dictation>\(text)</dictation>"

        if let prompt = systemPrompt, !prompt.isEmpty {
            result = prompt + "\n\n" + result
        }
        return result
    }

    /// Formats cursor context as XML, escaping special characters.
    /// Only includes child tags when their values are non-nil.
    private static func formatCursorContextXML(_ context: CursorContext) -> String {
        var xml = "<cursor_context>"

        if let before = context.beforeText {
            xml += "\n  <before>\(escapeXML(before))</before>"
        }
        if let after = context.afterText {
            xml += "\n  <after>\(escapeXML(after))</after>"
        }

        xml += "\n</cursor_context>"
        return xml
    }

    /// Escapes special XML characters: &, <, >, ", '
    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
