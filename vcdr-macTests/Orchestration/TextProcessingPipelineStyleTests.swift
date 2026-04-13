import Foundation
import Testing
@testable import vcdr_mac

// MARK: - TextProcessingPipeline Style Integration Tests

@Suite("TextProcessingPipeline — Style Integration")
struct TextProcessingPipelineStyleTests {

    // MARK: - Direct Mode Style Tests

    @Test("Direct mode applies casual style transformation")
    func directModeAppliesCasualStyle() async throws {
        let mode = Mode(
            id: UUID(),
            name: "Direct",
            processingType: .none,
            showPreview: false
        )
        let text = "Hello World."

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: text,
            captures: [],
            style: .casual
        )

        // Casual: lowercase sentence start, preserve internal caps, remove final period, trailing space
        #expect(result.text == "hello World ")
        #expect(result.hadExternalProcessing == false)
    }

    @Test("Direct mode applies formal style transformation")
    func directModeAppliesFormalStyle() async throws {
        let mode = Mode(
            id: UUID(),
            name: "Direct",
            processingType: .none,
            showPreview: false
        )
        let text = "hello world"

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: text,
            captures: [],
            style: .formal
        )

        // Formal: capitalize, add period, trailing space
        #expect(result.text == "Hello world. ")
        #expect(result.hadExternalProcessing == false)
    }

    // MARK: - Bash Mode Style Tests

    @Test("Bash mode applies style transformation after script execution")
    func bashModeAppliesStyleTransformation() async throws {
        let mode = Mode(
            id: UUID(),
            name: "Bash",
            processingType: .bashScript,
            processingCommand: "cat",
            showPreview: false
        )
        let text = "Hello World."

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: text,
            captures: [],
            variableEnvironment: [:],
            style: .casual
        )

        // Casual style applied to bash output: lowercase sentence start, preserve internal caps, trailing space
        #expect(result.text == "hello World ")
        #expect(result.hadExternalProcessing == true)
    }

    // MARK: - AI Mode Style Tests

    @Test("AI mode applies style transformation after AI processing")
    func aiModeAppliesStyleTransformation() async throws {
        struct MockAI: AIProcessingPort {
            func process(structuredText: String, mode: Mode, variableEnvironment: [String : String]) async throws -> String {
                return "Hello World."
            }
        }

        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let text = "hello world"

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: text,
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: MockAI(),
            style: .casual
        )

        // Casual style: lowercased, final period removed, trailing space
        #expect(result.text == "hello world ")
        #expect(result.hadExternalProcessing == true)
    }

    @Test("AI mode applies formal style to AI output")
    func aiModeAppliesFormalStyle() async throws {
        struct MockAI: AIProcessingPort {
            func process(structuredText: String, mode: Mode, variableEnvironment: [String : String]) async throws -> String {
                return "hello world"
            }
        }

        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let text = "test"

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: text,
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: MockAI(),
            style: .formal
        )

        // Formal: capitalized, period added, trailing space
        #expect(result.text == "Hello world. ")
        #expect(result.hadExternalProcessing == true)
    }

    // MARK: - Style with Filler Words Tests

    @Test("Style transformation applied after filler word removal")
    func styleAppliedAfterFillerRemoval() async throws {
        let mode = Mode(
            id: UUID(),
            name: "Direct",
            processingType: .none,
            showPreview: false
        )
        let text = "Um, Hello World."

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: text,
            captures: [],
            removeFillerWords: true,
            style: .casual
        )

        // Filler removed, then casual style: lowercase start, preserve internal caps, trailing space
        #expect(result.text == "hello World ")
    }

    // MARK: - Default Style Tests

    @Test("Default style is casual when not specified")
    func defaultStyleIsCasual() async throws {
        let mode = Mode(
            id: UUID(),
            name: "Direct",
            processingType: .none,
            showPreview: false
        )
        let text = "Hello World."

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: text,
            captures: []
        )

        // Default (casual) style: lowercase start, preserve internal caps, no final period, trailing space
        #expect(result.text == "hello World ")
    }
}
