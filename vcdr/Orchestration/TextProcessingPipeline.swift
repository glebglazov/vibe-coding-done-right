import Foundation

/// Result of running the text processing pipeline, including metadata
/// about whether external processing (e.g. a bash script) was invoked.
struct PipelineResult {
    let text: String
    /// True when the pipeline executed an external command (bash script)
    /// whose stdout became the output.
    let hadExternalProcessing: Bool
}

/// Result of the streaming pipeline variant.
struct StreamingPipelineResult {
    let chunks: AsyncThrowingStream<String, Error>
    let cancel: @Sendable () -> Void
    /// True when the pipeline executed an external command (bash script).
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

    /// Streaming variant: returns chunks as they arrive from the bash script.
    /// For `.none` modes, returns a single-chunk stream with the preprocessed text.
    static func runStreaming(
        mode: Mode,
        text: String,
        captures: [CapturedContext],
        parameterValues: [String: String] = [:]
    ) -> StreamingPipelineResult {
        let preprocessedText = mode.applyPreProcessing(text, captures: captures)

        switch mode.processingType {
        case .none:
            let stream = AsyncThrowingStream<String, Error> { continuation in
                continuation.yield(preprocessedText)
                continuation.finish()
            }
            return StreamingPipelineResult(chunks: stream, cancel: {}, hadExternalProcessing: false)
        case .bashScript:
            let paramEnv = Dictionary(
                uniqueKeysWithValues: parameterValues.map { ("VCDR_PARAM_\($0.key)", $0.value) }
            )
            let result = BashRunner.runStreaming(
                command: mode.processingCommand,
                text: preprocessedText,
                extraEnvironment: paramEnv
            )
            return StreamingPipelineResult(chunks: result.stream, cancel: result.cancel, hadExternalProcessing: true)
        }
    }
}
