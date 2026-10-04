import Foundation
import Testing
@testable import vcdr_mac

// MARK: - SubmissionPipeline Style Integration Tests

@Suite("SubmissionPipeline — Style Integration")
struct SubmissionPipelineStyleTests {

    @Test("Casual style produces lowercase, no-final-period, trailing-space output")
    func casualStyleProducesCorrectOutput() async throws {
        let context = SubmissionPipeline.Context(
            text: "Hello World. How Are You?",
            mode: Mode(id: UUID(), name: "Test", processingType: .none, showPreview: false),
            captures: [],
            conversationID: UUID(),
            parameterValues: [:],
            variableEnvironment: [:],
            destination: OutputDestination.makeDefaultCopy(),
            targetAppPID: nil,
            saveResultToClipboard: false,
            removeFillerWords: false,
            style: .casual
        )

        let result = try await SubmissionPipeline.process(context: context)

        // Casual: lowercase sentence starts, preserve internal caps, no final period, trailing space
        #expect(result.processedText == "hello World. how Are You? ")
    }

    @Test("Formal style produces capitalized, ending-punctuation, trailing-space output")
    func formalStyleProducesCorrectOutput() async throws {
        let context = SubmissionPipeline.Context(
            text: "hello world",
            mode: Mode(id: UUID(), name: "Test", processingType: .none, showPreview: false),
            captures: [],
            conversationID: UUID(),
            parameterValues: [:],
            variableEnvironment: [:],
            destination: OutputDestination.makeDefaultCopy(),
            targetAppPID: nil,
            saveResultToClipboard: false,
            removeFillerWords: false,
            style: .formal
        )

        let result = try await SubmissionPipeline.process(context: context)

        // Formal: capitalize first letter, add ending punctuation, trailing space
        #expect(result.processedText == "Hello world. ")
    }

    @Test("Style applied after AI processing in AI modes")
    func styleAppliedAfterAIProcessing() async throws {
        struct MockAI: AIProcessingPort {
            func process(structuredText: String, mode: Mode, spellingHints: SpellingHints, apiKey: String, parameterValues: [String: String]) async throws -> String {
                return "the quick brown fox jumps"
            }
        }

        let context = SubmissionPipeline.Context(
            text: "test input",
            mode: Mode(
                id: UUID(),
                name: "AI Test",
                processingType: .cloudAI,
                aiProvider: .anthropic,
                showPreview: false
            ),
            captures: [],
            conversationID: UUID(),
            parameterValues: [:],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            destination: OutputDestination.makeDefaultCopy(),
            targetAppPID: nil,
            saveResultToClipboard: false,
            removeFillerWords: false,
            style: .formal
        )

        let result = try await SubmissionPipeline.process(
            context: context,
            aiPort: MockAI()
        )

        // AI output transformed by formal style + trailing space
        #expect(result.hadExternalProcessing == true)
        #expect(result.processedText == "The quick brown fox jumps. ")
    }

    @Test("Style applied after bash processing in Bash modes")
    func styleAppliedAfterBashProcessing() async throws {
        let context = SubmissionPipeline.Context(
            text: "Hello World",
            mode: Mode(
                id: UUID(),
                name: "Bash Test",
                processingType: .bashScript,
                processingCommand: "echo -n \"$VCDR_TEXT\" | sed 's/<[^>]*>//g'",
                showPreview: false
            ),
            captures: [],
            conversationID: UUID(),
            parameterValues: [:],
            variableEnvironment: [:],
            destination: OutputDestination.makeDefaultCopy(),
            targetAppPID: nil,
            saveResultToClipboard: false,
            removeFillerWords: false,
            style: .casual
        )

        let result = try await SubmissionPipeline.process(context: context)

        // Bash output transformed by casual style + trailing space
        #expect(result.hadExternalProcessing == true)
        #expect(result.processedText == "hello World ")
    }

    @Test("Empty dynamicPrompt appends nothing in AI modes")
    func emptyDynamicPromptAppendsNothing() async throws {
        #expect(Style.casual.dynamicPrompt == nil)
        #expect(Style.formal.dynamicPrompt == nil)

        let systemPrompt = "You are a helpful assistant."
        let result = AIStylePromptAppender.appendStylePrompt(to: systemPrompt, style: .casual)

        #expect(result == systemPrompt)
    }
}
