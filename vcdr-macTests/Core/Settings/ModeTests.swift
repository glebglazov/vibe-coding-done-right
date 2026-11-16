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

    @Test("appliesStyles defaults to true when missing from JSON")
    @MainActor func appliesStylesDefaultsToTrue() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "processingType": "none",
            "processingCommand": ""
        }
        """
        let decoded = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        #expect(decoded.appliesStyles == true)
    }

    @Test("appliesStyles round-trips through encode/decode")
    @MainActor func appliesStylesRoundTrip() throws {
        let original = Mode(
            id: UUID(),
            name: "No Style",
            processingType: .none,
            appliesStyles: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        #expect(decoded.appliesStyles == false)
    }
}

@Suite("Mode.captureUse")
struct ModeCaptureUseTests {

    private func savedModeJSON(templateID: String?, captureField: String) -> String {
        let template = templateID.map { "\"templateID\":\"\($0)\"," } ?? ""
        return """
        {"id":"\(UUID().uuidString)","name":"Saved",\(template)\
        "processingType":"cloudAI","promptType":"dictation",\(captureField)}
        """
    }

    private func decodeSavedMode(templateID: String?, captureField: String) throws -> Mode {
        let json = Data(savedModeJSON(templateID: templateID, captureField: captureField).utf8)
        return try JSONDecoder().decode(Mode.self, from: json)
    }

    @Test("A saved Verbatim or Dictation Mode ignores captures whatever it stored", arguments: [
        "plain", "ai-dictation",
    ])
    func fixedTemplateModeIgnoresStoredCaptureUse(templateID: String) throws {
        for stored in CaptureUse.allCases {
            let mode = try decodeSavedMode(templateID: templateID, captureField: "\"captureUse\":\"\(stored.rawValue)\"")
            #expect(mode.captureUse == .ignored)
            #expect(!mode.usesCaptures)
        }
        let legacy = try decodeSavedMode(templateID: templateID, captureField: "\"appendCapturesToOutput\":true")
        #expect(legacy.captureUse == .ignored)
    }

    @Test("A saved Mode with the legacy dictation template ID ignores captures before it is migrated")
    func legacyDictationTemplateIgnoresCaptures() throws {
        let mode = try decodeSavedMode(templateID: "dictation", captureField: "\"captureUse\":\"sentAsInput\"")
        #expect(mode.captureUse == .ignored)
    }

    @Test("A user-created Mode keeps what its legacy append flag meant")
    func userModeKeepsLegacyCaptureUse() throws {
        let appending = try decodeSavedMode(templateID: nil, captureField: "\"appendCapturesToOutput\":true")
        let sending = try decodeSavedMode(templateID: nil, captureField: "\"appendCapturesToOutput\":false")
        #expect(appending.captureUse == .appendedToOutput)
        #expect(sending.captureUse == .sentAsInput)
    }

    @Test("An unknown stored capture use does not drop the saved Modes")
    @MainActor
    func unknownCaptureUseKeepsModes() throws {
        let defaults = try #require(UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)"))
        let unknown = savedModeJSON(templateID: nil, captureField: "\"captureUse\":\"futureValue\"")
        let known = savedModeJSON(templateID: nil, captureField: "\"captureUse\":\"appendedToOutput\"")
        defaults.set(Data("[\(unknown),\(known)]".utf8), forKey: "modes")

        let settings = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())

        #expect(settings.modes.map(\.name) == ["Saved", "Saved"])
        #expect(settings.modes.map(\.captureUse) == [.sentAsInput, .appendedToOutput])
    }

    @Test("A user-created Mode round-trips its capture use")
    func captureUseRoundTrips() throws {
        var mode = Mode(id: UUID(), name: "Custom")
        mode.captureUse = .ignored
        let decoded = try JSONDecoder().decode(Mode.self, from: JSONEncoder().encode(mode))
        #expect(decoded.captureUse == .ignored)
    }
}
