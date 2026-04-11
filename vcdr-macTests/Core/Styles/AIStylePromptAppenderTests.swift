import Foundation
import Testing
@testable import vcdr_mac

// MARK: - AIStylePromptAppender Tests

@Suite("AIStylePromptAppender")
struct AIStylePromptAppenderTests {

    @Test("Empty dynamic prompt returns original system prompt unchanged")
    func emptyDynamicPromptReturnsOriginal() {
        let style = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: .casual,
            dynamicPrompt: nil,
            associatedAppBundleIDs: []
        )
        let systemPrompt = "You are a helpful assistant."

        let result = AIStylePromptAppender.appendStylePrompt(to: systemPrompt, style: style)

        #expect(result == systemPrompt)
    }

    @Test("Empty string dynamic prompt returns original system prompt unchanged")
    func emptyStringDynamicPromptReturnsOriginal() {
        let style = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: .casual,
            dynamicPrompt: "",
            associatedAppBundleIDs: []
        )
        let systemPrompt = "You are a helpful assistant."

        let result = AIStylePromptAppender.appendStylePrompt(to: systemPrompt, style: style)

        #expect(result == systemPrompt)
    }

    @Test("Non-empty dynamic prompt appends to system prompt")
    func nonEmptyDynamicPromptAppends() {
        let style = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: .casual,
            dynamicPrompt: "Format all output in lowercase.",
            associatedAppBundleIDs: []
        )
        let systemPrompt = "You are a helpful assistant."

        let result = AIStylePromptAppender.appendStylePrompt(to: systemPrompt, style: style)

        #expect(result == "You are a helpful assistant.\n\nFormat all output in lowercase.")
    }

    @Test("Dynamic prompt appended to empty system prompt")
    func dynamicPromptAppendedToEmptySystemPrompt() {
        let style = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: .casual,
            dynamicPrompt: "Use formal language.",
            associatedAppBundleIDs: []
        )
        let systemPrompt = ""

        let result = AIStylePromptAppender.appendStylePrompt(to: systemPrompt, style: style)

        #expect(result == "Use formal language.")
    }

    @Test("hasDynamicPrompt returns false for nil dynamicPrompt")
    func hasDynamicPromptFalseForNil() {
        let style = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: .casual,
            dynamicPrompt: nil,
            associatedAppBundleIDs: []
        )

        #expect(!AIStylePromptAppender.hasDynamicPrompt(style))
    }

    @Test("hasDynamicPrompt returns false for empty dynamicPrompt")
    func hasDynamicPromptFalseForEmpty() {
        let style = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: .casual,
            dynamicPrompt: "",
            associatedAppBundleIDs: []
        )

        #expect(!AIStylePromptAppender.hasDynamicPrompt(style))
    }

    @Test("hasDynamicPrompt returns true for non-empty dynamicPrompt")
    func hasDynamicPromptTrueForNonEmpty() {
        let style = Style(
            id: UUID(),
            name: "Test",
            isBuiltIn: false,
            isDefault: false,
            staticRules: .casual,
            dynamicPrompt: "Some instructions",
            associatedAppBundleIDs: []
        )

        #expect(AIStylePromptAppender.hasDynamicPrompt(style))
    }

    @Test("Built-in casual style has no dynamic prompt")
    func builtInCasualHasNoDynamicPrompt() {
        #expect(!AIStylePromptAppender.hasDynamicPrompt(.casual))

        let systemPrompt = "You are helpful."
        let result = AIStylePromptAppender.appendStylePrompt(to: systemPrompt, style: .casual)

        #expect(result == systemPrompt)
    }

    @Test("Built-in formal style has no dynamic prompt")
    func builtInFormalHasNoDynamicPrompt() {
        #expect(!AIStylePromptAppender.hasDynamicPrompt(.formal))

        let systemPrompt = "You are helpful."
        let result = AIStylePromptAppender.appendStylePrompt(to: systemPrompt, style: .formal)

        #expect(result == systemPrompt)
    }
}
