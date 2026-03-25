import Foundation

/// Result of running the text processing pipeline, including metadata
/// about whether external processing (e.g. a bash script) was invoked.
struct PipelineResult {
    let text: String
    /// True when the pipeline executed an external command (bash script)
    /// whose stdout became the output.
    let hadExternalProcessing: Bool
}

enum TextProcessingPipeline {
    /// Runs the text processing pipeline: pre-processing (system prompt, captured context)
    /// followed by optional bash script execution.
    static func run(
        mode: Mode,
        text: String,
        captures: [CapturedContext],
        parameterValues: [String: String] = [:]
    ) async throws -> PipelineResult {
        let preprocessedText = mode.applyPreProcessing(text, captures: captures)

        switch mode.processingType {
        case .none:
            return PipelineResult(text: preprocessedText, hadExternalProcessing: false)
        case .bashScript:
            let paramEnv = Dictionary(
                uniqueKeysWithValues: parameterValues.map { ("VCDR_PARAM_\($0.key)", $0.value) }
            )
            let processedText = try await BashRunner.run(
                command: mode.processingCommand,
                text: preprocessedText,
                extraEnvironment: paramEnv
            )
            return PipelineResult(text: processedText, hadExternalProcessing: true)
        }
    }
}
