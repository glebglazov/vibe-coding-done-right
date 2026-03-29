import Foundation
import OSLog

/// Result of running the text processing pipeline, including metadata
/// about whether external processing (e.g. a bash script) was invoked.
struct PipelineResult {
    let text: String
    /// True when the pipeline executed an external command (bash script or companion)
    /// whose stdout became the output.
    let hadExternalProcessing: Bool
    /// When companion processing fails, this contains the raw text and error message
    /// so the caller can offer a preview with retry.
    let companionFallback: CompanionFallback?
}

struct CompanionFallback {
    let rawText: String
    let errorMessage: String
}

enum TextProcessingPipeline {

    /// Runs the three-stage text processing pipeline:
    /// 1. Algorithmic pre-processing — speech cleanup (filler word removal)
    /// 2. External processing — input structuring + content processing (none/bash/companion)
    /// 3. Algorithmic post-processing — output formatting (terminator)
    static func run(
        mode: Mode,
        text: String,
        captures: [CapturedContext],
        parameterValues: [String: String] = [:],
        variableEnvironment: [String: String] = [:],
        companionHost: String = "",
        companionApiKey: String = "",
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
            result = PipelineResult(text: structured, hadExternalProcessing: false, companionFallback: nil)

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
            result = PipelineResult(text: processedText, hadExternalProcessing: true, companionFallback: nil)

        case .companion:
            do {
                let processedText = try await CompanionClient.process(
                    text: structured,
                    host: companionHost,
                    apiKey: companionApiKey,
                    integrationMode: mode.companionIntegrationMode
                )
                result = PipelineResult(text: processedText, hadExternalProcessing: true, companionFallback: nil)
            } catch {
                Logger.app.warning("Companion processing failed, reprocessing as .none: \(error)")
                // Companion failed — reprocess as if processing type were .none.
                // Structure input for human-readable output (plaintext captures).
                let fallbackText = structureInputPlaintext(text: cleanedText, captures: captures)
                // companionFallback.rawText stores cleanedText (no structuring) for retry.
                result = PipelineResult(
                    text: fallbackText,
                    hadExternalProcessing: false,
                    companionFallback: CompanionFallback(rawText: cleanedText, errorMessage: error.localizedDescription)
                )
            }
        }

        // MARK: Algorithmic post-processing — output formatting
        let finalText = terminatorTemplateEnabled
            ? Mode.applyTerminator(result.text, terminator: terminatorTemplate)
            : result.text

        return PipelineResult(
            text: finalText,
            hadExternalProcessing: result.hadExternalProcessing,
            companionFallback: result.companionFallback
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
        case .bashScript, .companion:
            return structureInputXML(text: text, captures: captures, mode: mode)
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

    /// XML input structuring for .bashScript/.companion — <dictation> wrapping,
    /// optional system prompt, and XML capture tags for machine-parseable input.
    private static func structureInputXML(
        text: String,
        captures: [CapturedContext],
        mode: Mode
    ) -> String {
        var result = "<dictation>\(text)</dictation>"
        if mode.systemPromptEnabled && !mode.systemPrompt.isEmpty {
            result = mode.systemPrompt + "\n\n" + result
        }
        if !captures.isEmpty {
            result += "\n\n" + Mode.formatCaptures(captures)
        }
        return result
    }
}
