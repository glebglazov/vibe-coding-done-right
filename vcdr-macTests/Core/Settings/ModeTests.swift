import Foundation
import Testing
@testable import vcdr_mac

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
    showPreview: Bool = false
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
        showPreview: showPreview
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

// MARK: - formatCaptures

@Suite("Mode.formatCaptures")
struct ModeFormatCapturesTests {

    @Test("Single capture produces capture tag with id=1")
    @MainActor func singleCapture() {
        let captures = [CapturedContext(text: "selected text", source: .selection)]
        #expect(Mode.formatCaptures(captures) == "<capture id=\"1\">selected text</capture>")
    }

    @Test("Multiple captures produce sequential capture tags")
    @MainActor func multipleCaptures() {
        let captures = [
            CapturedContext(text: "first", source: .selection),
            CapturedContext(text: "second", source: .clipboard)
        ]
        let expected = "<capture id=\"1\">first</capture>\n\n<capture id=\"2\">second</capture>"
        #expect(Mode.formatCaptures(captures) == expected)
    }

    @Test("Empty captures returns empty string")
    @MainActor func emptyCaptures() {
        #expect(Mode.formatCaptures([]) == "")
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
