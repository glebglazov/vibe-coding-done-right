import Foundation
import Testing
@testable import vcdr

// MARK: - Test Helpers

/// Creates a Mode with sensible defaults for testing.
/// Only `id`, `name`, and the parameters under test need to be specified.
@MainActor
private func makeMode(
    id: UUID = UUID(),
    name: String = "Test",
    processingType: ProcessingType = .none,
    processingCommand: String = "",
    systemPromptEnabled: Bool = false,
    systemPrompt: String = "",
    quickAction: Bool = false
) -> Mode {
    Mode(
        id: id,
        name: name,
        isDisabled: false,
        templateID: nil,
        processingType: processingType,
        processingCommand: processingCommand,
        systemPromptEnabled: systemPromptEnabled,
        systemPrompt: systemPrompt,
        defaultOutputDestinationID: OutputDestination.builtInPasteID,
        parameters: [],
        quickAction: quickAction
    )
}

// MARK: - applyTerminator

@Suite("Mode.applyTerminator")
struct ModeApplyTerminatorTests {

    @Test("Returns text unchanged when terminator is empty")
    @MainActor func emptyTerminator() {
        #expect(Mode.applyTerminator("Hello", terminator: "") == "Hello")
    }

    @Test("Returns text unchanged when text is whitespace-only")
    @MainActor func whitespaceOnlyText() {
        #expect(Mode.applyTerminator("   ", terminator: "<dot><space>") == "   ")
    }

    @Test("Returns text unchanged when text is empty")
    @MainActor func emptyText() {
        #expect(Mode.applyTerminator("", terminator: "<dot><space>") == "")
    }

    @Test("Resolves <dot> token to period")
    @MainActor func dotToken() {
        #expect(Mode.applyTerminator("Hello", terminator: "<dot>") == "Hello.")
    }

    @Test("Resolves <space> token to space")
    @MainActor func spaceToken() {
        #expect(Mode.applyTerminator("Hello", terminator: "<space>") == "Hello ")
    }

    @Test("Resolves <newline> token to newline")
    @MainActor func newlineToken() {
        #expect(Mode.applyTerminator("Hello", terminator: "<newline>") == "Hello\n")
    }

    @Test("Resolves compound <dot><space> template")
    @MainActor func dotSpaceTemplate() {
        #expect(Mode.applyTerminator("Hello world", terminator: "<dot><space>") == "Hello world. ")
    }

    @Test("Resolves <dot><newline> template")
    @MainActor func dotNewlineTemplate() {
        #expect(Mode.applyTerminator("Hello", terminator: "<dot><newline>") == "Hello.\n")
    }

    @Test("Strips leading/trailing whitespace from text before appending")
    @MainActor func trims() {
        #expect(Mode.applyTerminator("  Hello  ", terminator: "<dot>") == "Hello.")
    }

    @Test(
        "Skips punctuation prefix when text already ends with sentence-ending punctuation",
        arguments: [
            ("Hello.", "<dot><space>", "Hello. "),
            ("Hello?", "<dot><space>", "Hello? "),
            ("Hello!", "<dot><space>", "Hello! "),
        ]
    )
    @MainActor func skipsRedundantPunctuation(text: String, terminator: String, expected: String) {
        #expect(Mode.applyTerminator(text, terminator: terminator) == expected)
    }

    @Test("Appends full terminator when text ends with non-sentence punctuation")
    @MainActor func nonSentencePunctuation() {
        #expect(Mode.applyTerminator("Hello,", terminator: "<dot><space>") == "Hello,. ")
    }

    @Test("Terminator with only spacing and no punctuation prefix appends as-is")
    @MainActor func spacingOnlyTerminator() {
        #expect(Mode.applyTerminator("Hello.", terminator: "<space>") == "Hello. ")
        #expect(Mode.applyTerminator("Hello", terminator: "<space>") == "Hello ")
    }

    @Test("Literal characters pass through without token replacement")
    @MainActor func literalTerminator() {
        #expect(Mode.applyTerminator("Hello", terminator: " -") == "Hello -")
    }
}

// MARK: - applyPreProcessing

@Suite("Mode.applyPreProcessing")
struct ModeApplyPreProcessingTests {

    @Test("Returns text as-is when all options disabled")
    @MainActor func passthrough() {
        let mode = makeMode()
        #expect(mode.applyPreProcessing("hello", captures: []) == "hello")
    }

    @Test("Prepends follow-up context before new dictation")
    @MainActor func followUpContext() {
        let mode = makeMode()
        let result = mode.applyPreProcessing("new text", captures: [], followUpContext: "previous")
        #expect(result == "previous\n\nnew text")
    }

    @Test("Prepends system prompt when bash processing and system prompt enabled")
    @MainActor func systemPromptWithBash() {
        let mode = makeMode(
            processingType: .bashScript,
            systemPromptEnabled: true,
            systemPrompt: "Fix grammar:"
        )
        #expect(mode.applyPreProcessing("hello world", captures: []) == "Fix grammar:\n\nhello world")
    }

    @Test("Does NOT prepend system prompt when processing type is none")
    @MainActor func systemPromptIgnoredForNoneType() {
        let mode = makeMode(
            processingType: .none,
            systemPromptEnabled: true,
            systemPrompt: "Fix grammar:"
        )
        #expect(mode.applyPreProcessing("hello world", captures: []) == "hello world")
    }

    @Test("Does NOT prepend system prompt when system prompt disabled")
    @MainActor func systemPromptDisabled() {
        let mode = makeMode(
            processingType: .bashScript,
            systemPromptEnabled: false,
            systemPrompt: "Fix grammar:"
        )
        #expect(mode.applyPreProcessing("hello world", captures: []) == "hello world")
    }

    @Test("Does NOT prepend system prompt when system prompt is empty")
    @MainActor func systemPromptEmpty() {
        let mode = makeMode(
            processingType: .bashScript,
            systemPromptEnabled: true,
            systemPrompt: ""
        )
        #expect(mode.applyPreProcessing("hello world", captures: []) == "hello world")
    }

    @Test("Appends captured selection after text")
    @MainActor func capturedSelection() {
        let mode = makeMode()
        let captures = [CapturedContext(text: "selected text", source: .selection)]
        #expect(mode.applyPreProcessing("rewrite this", captures: captures)
            == "rewrite this\n\n<capture-1>selected text</capture-1>")
    }

    @Test("Full pipeline: follow-up + system prompt + captures in correct order")
    @MainActor func fullPipeline() {
        let mode = makeMode(
            processingType: .bashScript,
            systemPromptEnabled: true,
            systemPrompt: "Prompt:"
        )
        let captures = [CapturedContext(text: "selection", source: .selection)]
        let result = mode.applyPreProcessing(
            "dictation",
            captures: captures,
            followUpContext: "context"
        )
        // Order: follow-up prepended → system prompt prepended → captures appended
        #expect(result == "Prompt:\n\ncontext\n\ndictation\n\n<capture-1>selection</capture-1>")
    }
}

// MARK: - Codable Migration

@Suite("Mode Codable migration")
struct ModeCodableTests {

    @Test("Round-trips through encode/decode preserving all fields")
    @MainActor func roundTrip() throws {
        let original = makeMode(
            processingType: .bashScript,
            processingCommand: "echo $VCDR_TEXT",
            systemPromptEnabled: true,
            systemPrompt: "Fix it"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decodes legacy actionType=bash as processingType=bashScript")
    @MainActor func legacyBashMigration() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "actionType": "bash",
            "bashCommand": "echo hello"
        }
        """
        let decoded = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        #expect(decoded.processingType == .bashScript)
        #expect(decoded.processingCommand == "echo hello")
    }

    @Test("Decodes legacy actionType=paste as processingType=none")
    @MainActor func legacyPasteMigration() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy"
        }
        """
        let decoded = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        #expect(decoded.processingType == .none)
        #expect(decoded.processingCommand == "")
    }

    @Test("Missing optional fields get correct defaults")
    @MainActor func defaultValues() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Minimal",
            "processingType": "none",
            "processingCommand": ""
        }
        """
        let decoded = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        #expect(decoded.systemPromptEnabled == false)
        #expect(decoded.systemPrompt == "")
    }
}
