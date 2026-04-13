import Foundation
import Testing
@testable import vcdr_mac

// MARK: - Mock AI with Capturing

@MainActor
final class CapturingMockAI: AIProcessingPort {
    var capturedText: String?

    func process(structuredText: String, mode: Mode, variableEnvironment: [String: String]) async throws -> String {
        capturedText = structuredText
        return "processed"
    }
}

// MARK: - TextProcessingPipeline Cursor Context XML Tests

@Suite("TextProcessingPipeline — Cursor Context XML")
@MainActor
struct TextProcessingPipelineCursorContextTests {

    // MARK: - XML Output with Cursor Context Tests

    @Test("Cloud AI mode includes cursor context tags when context is available")
    func cloudAIModeIncludesCursorContext() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: "Hello ",
            afterText: " world",
            sourceBundleID: "com.test.app"
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "test dictation",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        #expect(captured.contains("<cursor_context>"))
        #expect(captured.contains("<before>Hello </before>"))
        #expect(captured.contains("<after> world</after>"))
        #expect(captured.contains("<dictation>test dictation</dictation>"))
    }

    @Test("Cloud AI mode omits cursor context tags when context is nil")
    func cloudAIModeOmitsCursorContextWhenNil() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "test dictation",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: nil
        )

        let captured = try #require(mockAI.capturedText)
        #expect(!captured.contains("<cursor_context>"))
        #expect(!captured.contains("<before>"))
        #expect(!captured.contains("<after>"))
        #expect(captured.contains("<dictation>test dictation</dictation>"))
    }

    // MARK: - XML Structure Tests

    @Test("Cursor context includes both before and after text")
    func cursorContextIncludesBothTexts() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: "The beginning ",
            afterText: " the end",
            sourceBundleID: "com.test.app"
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "middle",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        #expect(captured.contains("<cursor_context>"))
        #expect(captured.contains("<before>The beginning </before>"))
        #expect(captured.contains("<after> the end</after>"))
    }

    @Test("Cursor context omits before tag when beforeText is nil")
    func cursorContextOmitsBeforeWhenNil() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: nil,
            afterText: "after only",
            sourceBundleID: "com.test.app"
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "dictation",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        #expect(captured.contains("<cursor_context>"))
        #expect(!captured.contains("<before>"))
        #expect(captured.contains("<after>after only</after>"))
    }

    @Test("Cursor context omits after tag when afterText is nil")
    func cursorContextOmitsAfterWhenNil() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: "before only",
            afterText: nil,
            sourceBundleID: "com.test.app"
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "dictation",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        #expect(captured.contains("<cursor_context>"))
        #expect(captured.contains("<before>before only</before>"))
        #expect(!captured.contains("<after>"))
    }

    @Test("Cursor context omits entire block when both texts are nil")
    func cursorContextOmitsBothWhenNil() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: nil,
            afterText: nil,
            sourceBundleID: "com.test.app"
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "dictation",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        #expect(!captured.contains("<cursor_context>"))
        #expect(!captured.contains("<before>"))
        #expect(!captured.contains("<after>"))
        #expect(captured.contains("<dictation>dictation</dictation>"))
    }

    // MARK: - XML Escaping Tests

    @Test("XML special characters in before text are properly escaped")
    func beforeTextXMLEscaping() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: "5 < 10 && 10 > 5 with \"quotes\" and 'apostrophes'",
            afterText: nil,
            sourceBundleID: "com.test.app"
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "test",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        #expect(captured.contains("<before>5 &lt; 10 &amp;&amp; 10 &gt; 5 with &quot;quotes&quot; and &apos;apostrophes&apos;</before>"))
        #expect(!captured.contains("<before>5 < 10 && 10 > 5"))
    }

    @Test("XML special characters in after text are properly escaped")
    func afterTextXMLEscaping() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: nil,
            afterText: "if (x < 0 && y > 100) { \"result\" = 'value' }",
            sourceBundleID: "com.test.app"
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "test",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        #expect(captured.contains("<after>if (x &lt; 0 &amp;&amp; y &gt; 100) { &quot;result&quot; = &apos;value&apos; }</after>"))
        #expect(!captured.contains("<after>if (x < 0 && y > 100)"))
    }

    @Test("XML special characters in both texts are escaped")
    func bothTextsXMLEscaping() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: "<tag> & more",
            afterText: "less & </tag>",
            sourceBundleID: "com.test.app"
        )

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "middle",
            captures: [],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        #expect(captured.contains("<before>&lt;tag&gt; &amp; more</before>"))
        #expect(captured.contains("<after>less &amp; &lt;/tag&gt;</after>"))
    }

    // MARK: - Bash Script Mode Tests

    @Test("Bash script mode includes cursor context when enabled with prompt")
    func bashScriptModeIncludesCursorContext() async throws {
        let mode = Mode(
            id: UUID(),
            name: "Bash",
            processingType: .bashScript,
            processingCommand: "echo -n \"$VCDR_TEXT\"",
            systemPromptEnabled: true,
            systemPrompt: "Test prompt",
            showPreview: false
        )
        let context = CursorContext(
            beforeText: "Before",
            afterText: "After",
            sourceBundleID: "com.test.app"
        )

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "test",
            captures: [],
            cursorContext: context
        )

        // The cat command just echoes input, so result should contain the XML structure
        #expect(result.text.contains("<cursor_context>"))
        #expect(result.text.contains("<before>Before</before>"))
        #expect(result.text.contains("<after>After</after>"))
    }

    @Test("Bash script mode with no context omits cursor context tags")
    func bashScriptModeOmitsCursorContextWhenNil() async throws {
        let mode = Mode(
            id: UUID(),
            name: "Bash",
            processingType: .bashScript,
            processingCommand: "echo -n \"$VCDR_TEXT\"",
            systemPromptEnabled: false,
            showPreview: false
        )

        let result = try await TextProcessingPipeline.run(
            mode: mode,
            text: "test",
            captures: [],
            cursorContext: nil
        )

        #expect(!result.text.contains("<cursor_context>"))
        #expect(result.text.contains("<dictation>test</dictation>"))
    }

    // MARK: - Combined with Captures Tests

    @Test("Cursor context appears before dictation when captures are present")
    func cursorContextBeforeDictationWithCaptures() async throws {
        let mockAI = CapturingMockAI()
        let mode = Mode(
            id: UUID(),
            name: "AI",
            processingType: .cloudAI,
            aiProvider: .anthropic,
            showPreview: false
        )
        let context = CursorContext(
            beforeText: "Context",
            afterText: nil,
            sourceBundleID: "com.test.app"
        )
        let capture = CapturedContext(text: "captured text", source: .selection)

        _ = try? await TextProcessingPipeline.run(
            mode: mode,
            text: "dictation",
            captures: [capture],
            variableEnvironment: ["ANTHROPIC_API_KEY": "test-key"],
            aiPort: mockAI,
            cursorContext: context
        )

        let captured = try #require(mockAI.capturedText)
        // Verify order: cursor_context, then dictation, then captures
        let cursorRange = captured.range(of: "<cursor_context>")
        let dictationRange = captured.range(of: "<dictation>")
        let captureRange = captured.range(of: "<capture")

        let cursorIndex = cursorRange?.lowerBound.utf16Offset(in: captured)
        let dictationIndex = dictationRange?.lowerBound.utf16Offset(in: captured)
        let captureIndex = captureRange?.lowerBound.utf16Offset(in: captured)

        #expect(cursorIndex! < dictationIndex!)
        #expect(dictationIndex! < captureIndex!)
    }
}
