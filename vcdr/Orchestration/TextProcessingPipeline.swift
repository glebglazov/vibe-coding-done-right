import Foundation

enum TextProcessingPipeline {
    /// Runs the text processing pipeline: pre-processing (terminator, system prompt,
    /// follow-up context, captured selection) followed by optional bash script execution.
    static func run(
        mode: Mode,
        text: String,
        capturedSelection: String?,
        followUpContext: String?,
        conversationID: UUID
    ) async throws -> String {
        // Step 1: Pre-processing (terminator, system prompt, follow-up context, captured selection)
        let preprocessedText = mode.applyPreProcessing(text, capturedSelection: capturedSelection, followUpContext: followUpContext)

        // Step 2: Processing (optional bash script)
        switch mode.processingType {
        case .none:
            return preprocessedText
        case .bashScript:
            return try await BashRunner.run(
                command: mode.processingCommand,
                text: preprocessedText,
                conversationID: conversationID.uuidString
            )
        }
    }
}
