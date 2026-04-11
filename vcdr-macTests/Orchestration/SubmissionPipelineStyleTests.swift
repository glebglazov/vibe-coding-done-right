import Foundation
import Testing
@testable import vcdr_mac

// MARK: - SubmissionPipeline Style Integration Tests

@Suite("SubmissionPipeline — Style Integration")
struct SubmissionPipelineStyleTests {

    @Test("Casual style produces lowercase, no-final-period output")
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
            terminatorTemplateEnabled: false,
            terminatorTemplate: "",
            style: .casual
        )

        struct MockAI: AIProcessingPort {
            func process(structuredText: String, mode: Mode, variableEnvironment: [String : String]) async throws -> String {
                return "AI Processed: \(structuredText)"
            }
        }

        let result = try await SubmissionPipeline.process(
            context: context,
            aiPort: MockAI()
        )

        // Casual: lowercase sentences, no final period
        #expect(result.processedText == "hello world. how are you?")
    }

    @Test("Formal style produces capitalized, ending-punctuation output")
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
            terminatorTemplateEnabled: false,
            terminatorTemplate: "",
            style: .formal
        )

        let result = try await SubmissionPipeline.process(context: context)

        // Formal: capitalize first letter, add ending punctuation
        #expect(result.processedText == "Hello world.")
    }

    @Test("Style applied after AI processing in AI modes")
    func styleAppliedAfterAIProcessing() async throws {
        struct MockAI: AIProcessingPort {
            func process(structuredText: String, mode: Mode, variableEnvironment: [String : String]) async throws -> String {
                // AI returns mixed case without proper punctuation
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
            terminatorTemplateEnabled: false,
            terminatorTemplate: "",
            style: .formal
        )

        let result = try await SubmissionPipeline.process(
            context: context,
            aiPort: MockAI()
        )

        // AI output was transformed by formal style
        #expect(result.hadExternalProcessing == true)
        #expect(result.processedText == "The quick brown fox jumps.")
    }

    @Test("Style applied after bash processing in Bash modes")
    func styleAppliedAfterBashProcessing() async throws {
        let context = SubmissionPipeline.Context(
            text: "HELLO WORLD",
            mode: Mode(
                id: UUID(),
                name: "Bash Test",
                processingType: .bashScript,
                processingCommand: "cat",  // Echoes input
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
            terminatorTemplateEnabled: false,
            terminatorTemplate: "",
            style: .casual
        )

        let result = try await SubmissionPipeline.process(context: context)

        // Bash output was transformed by casual style
        #expect(result.hadExternalProcessing == true)
        #expect(result.processedText == "hello world")
    }

    @Test("Empty dynamicPrompt appends nothing in AI modes")
    func emptyDynamicPromptAppendsNothing() async throws {
        // Both built-in styles have nil dynamicPrompt
        #expect(Style.casual.dynamicPrompt == nil)
        #expect(Style.formal.dynamicPrompt == nil)

        // AIStylePromptAppender should not modify the prompt
        let systemPrompt = "You are a helpful assistant."
        let result = AIStylePromptAppender.appendStylePrompt(to: systemPrompt, style: .casual)

        #expect(result == systemPrompt)
    }

    @Test("Style transform is final step in pipeline")
    func styleTransformIsFinalStep() async throws {
        let context = SubmissionPipeline.Context(
            text: "HELLO. WORLD.",
            mode: Mode(id: UUID(), name: "Test", processingType: .none, showPreview: false),
            captures: [],
            conversationID: UUID(),
            parameterValues: [:],
            variableEnvironment: [:],
            destination: OutputDestination.makeDefaultCopy(),
            targetAppPID: nil,
            saveResultToClipboard: false,
            removeFillerWords: false,
            terminatorTemplateEnabled: true,
            terminatorTemplate: "<newline>",
            style: .casual
        )

        let result = try await SubmissionPipeline.process(context: context)

        // Style applied (lowercase, remove final period), then terminator applied
        // Casual removes final period, then terminator adds newline
        #expect(result.processedText == "hello. world\n")
    }
}
