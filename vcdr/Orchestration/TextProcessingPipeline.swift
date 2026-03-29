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
        parameterValues: [String: String] = [:],
        variableEnvironment: [String: String] = [:],
        companionHost: String = "",
        companionApiKey: String = ""
    ) async throws -> PipelineResult {
        let preprocessedText = mode.applyPreProcessing(text, captures: captures)

        switch mode.processingType {
        case .none:
            return PipelineResult(text: preprocessedText, hadExternalProcessing: false)
        case .bashScript:
            let paramEnv = Dictionary(
                uniqueKeysWithValues: parameterValues.map { ("VCDR_PARAM_\($0.key)", $0.value) }
            )
            // User variables first, then parameter env vars take precedence
            var combinedEnv = variableEnvironment
            combinedEnv.merge(paramEnv) { _, param in param }
            let processedText = try await BashRunner.run(
                command: mode.processingCommand,
                text: preprocessedText,
                extraEnvironment: combinedEnv
            )
            return PipelineResult(text: processedText, hadExternalProcessing: true)
        case .companion:
            let processedText = try await CompanionClient.process(
                text: preprocessedText,
                host: companionHost,
                apiKey: companionApiKey,
                integrationMode: mode.companionIntegrationMode
            )
            return PipelineResult(text: processedText, hadExternalProcessing: true)
        }
    }
}
