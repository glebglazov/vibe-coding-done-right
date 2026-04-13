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
