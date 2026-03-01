import Foundation
import Testing
@testable import vcdr

// MARK: - applyTerminator

@Suite("Mode.applyTerminator")
struct ModeApplyTerminatorTests {

    @Test("Returns text unchanged when terminator is empty")
    func emptyTerminator() {
        #expect(Mode.applyTerminator("Hello", terminator: "") == "Hello")
    }

    @Test("Returns text unchanged when text is whitespace-only")
    func whitespaceOnlyText() {
        #expect(Mode.applyTerminator("   ", terminator: "<dot><space>") == "   ")
    }

    @Test("Returns text unchanged when text is empty")
    func emptyText() {
        #expect(Mode.applyTerminator("", terminator: "<dot><space>") == "")
    }

    @Test("Resolves <dot> token to period")
    func dotToken() {
        #expect(Mode.applyTerminator("Hello", terminator: "<dot>") == "Hello.")
    }

    @Test("Resolves <space> token to space")
    func spaceToken() {
        #expect(Mode.applyTerminator("Hello", terminator: "<space>") == "Hello ")
    }

    @Test("Resolves <newline> token to newline")
    func newlineToken() {
        #expect(Mode.applyTerminator("Hello", terminator: "<newline>") == "Hello\n")
    }

    @Test("Resolves compound <dot><space> template")
    func dotSpaceTemplate() {
        #expect(Mode.applyTerminator("Hello world", terminator: "<dot><space>") == "Hello world. ")
    }

    @Test("Resolves <dot><newline> template")
    func dotNewlineTemplate() {
        #expect(Mode.applyTerminator("Hello", terminator: "<dot><newline>") == "Hello.\n")
    }

    @Test("Strips leading/trailing whitespace from text before appending")
    func trims() {
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
    func skipsRedundantPunctuation(text: String, terminator: String, expected: String) {
        #expect(Mode.applyTerminator(text, terminator: terminator) == expected)
    }

    @Test("Appends full terminator when text ends with non-sentence punctuation")
    func nonSentencePunctuation() {
        // Comma is not in sentenceEndingPunctuation, so the full terminator is appended
        #expect(Mode.applyTerminator("Hello,", terminator: "<dot><space>") == "Hello,. ")
    }

    @Test("Terminator with only spacing and no punctuation prefix appends as-is")
    func spacingOnlyTerminator() {
        #expect(Mode.applyTerminator("Hello.", terminator: "<space>") == "Hello. ")
        #expect(Mode.applyTerminator("Hello", terminator: "<space>") == "Hello ")
    }

    @Test("Literal characters pass through without token replacement")
    func literalTerminator() {
        #expect(Mode.applyTerminator("Hello", terminator: " -") == "Hello -")
    }
}

// MARK: - applyPreProcessing

@Suite("Mode.applyPreProcessing")
struct ModeApplyPreProcessingTests {

    @Test("Returns text as-is when all options disabled")
    func passthrough() {
        let mode = Mode(id: UUID(), name: "Test")
        #expect(mode.applyPreProcessing("hello", capturedSelection: nil) == "hello")
    }

    @Test("Applies terminator when enabled")
    func terminatorEnabled() {
        let mode = Mode(
            id: UUID(), name: "Test",
            terminatorTemplateEnabled: true,
            terminatorTemplate: "<dot><space>"
        )
        #expect(mode.applyPreProcessing("hello", capturedSelection: nil) == "hello. ")
    }

    @Test("Does not apply terminator when disabled")
    func terminatorDisabled() {
        let mode = Mode(
            id: UUID(), name: "Test",
            terminatorTemplateEnabled: false,
            terminatorTemplate: "<dot><space>"
        )
        #expect(mode.applyPreProcessing("hello", capturedSelection: nil) == "hello")
    }

    @Test("Prepends follow-up context before new dictation")
    func followUpContext() {
        let mode = Mode(id: UUID(), name: "Test")
        let result = mode.applyPreProcessing("new text", capturedSelection: nil, followUpContext: "previous")
        #expect(result == "previous\n\nnew text")
    }

    @Test("Prepends system prompt when bash processing and system prompt enabled")
    func systemPromptWithBash() {
        let mode = Mode(
            id: UUID(), name: "Test",
            processingType: .bashScript,
            systemPromptEnabled: true,
            systemPrompt: "Fix grammar:"
        )
        #expect(mode.applyPreProcessing("hello world", capturedSelection: nil) == "Fix grammar:\n\nhello world")
    }

    @Test("Does NOT prepend system prompt when processing type is none")
    func systemPromptIgnoredForNoneType() {
        let mode = Mode(
            id: UUID(), name: "Test",
            processingType: .none,
            systemPromptEnabled: true,
            systemPrompt: "Fix grammar:"
        )
        #expect(mode.applyPreProcessing("hello world", capturedSelection: nil) == "hello world")
    }

    @Test("Does NOT prepend system prompt when system prompt disabled")
    func systemPromptDisabled() {
        let mode = Mode(
            id: UUID(), name: "Test",
            processingType: .bashScript,
            systemPromptEnabled: false,
            systemPrompt: "Fix grammar:"
        )
        #expect(mode.applyPreProcessing("hello world", capturedSelection: nil) == "hello world")
    }

    @Test("Does NOT prepend system prompt when system prompt is empty")
    func systemPromptEmpty() {
        let mode = Mode(
            id: UUID(), name: "Test",
            processingType: .bashScript,
            systemPromptEnabled: true,
            systemPrompt: ""
        )
        #expect(mode.applyPreProcessing("hello world", capturedSelection: nil) == "hello world")
    }

    @Test("Appends captured selection after text")
    func capturedSelection() {
        let mode = Mode(id: UUID(), name: "Test")
        #expect(mode.applyPreProcessing("rewrite this", capturedSelection: "selected text") == "rewrite this\n\nselected text")
    }

    @Test("Full pipeline: terminator + follow-up + system prompt + selection in correct order")
    func fullPipeline() {
        let mode = Mode(
            id: UUID(), name: "Test",
            processingType: .bashScript,
            terminatorTemplateEnabled: true,
            terminatorTemplate: "<dot>",
            systemPromptEnabled: true,
            systemPrompt: "Prompt:"
        )
        let result = mode.applyPreProcessing(
            "dictation",
            capturedSelection: "selection",
            followUpContext: "context"
        )
        // Order: terminator applied to text → follow-up prepended → system prompt prepended → selection appended
        #expect(result == "Prompt:\n\ncontext\n\ndictation.\n\nselection")
    }
}

// MARK: - Codable Migration

@Suite("Mode Codable migration")
struct ModeCodableTests {

    @Test("Round-trips through encode/decode preserving all fields")
    func roundTrip() throws {
        let original = Mode(
            id: UUID(),
            name: "My Mode",
            processingType: .bashScript,
            processingCommand: "echo $VCDR_TEXT",
            terminatorTemplateEnabled: true,
            terminatorTemplate: "<dot><newline>",
            systemPromptEnabled: true,
            systemPrompt: "Fix it"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decodes legacy actionType=bash as processingType=bashScript")
    func legacyBashMigration() throws {
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
    func legacyPasteMigration() throws {
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
    func defaultValues() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Minimal",
            "processingType": "none",
            "processingCommand": ""
        }
        """
        let decoded = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        #expect(decoded.terminatorTemplateEnabled == false)
        #expect(decoded.terminatorTemplate == Mode.defaultTerminatorTemplate)
        #expect(decoded.systemPromptEnabled == false)
        #expect(decoded.systemPrompt == "")
    }
}
