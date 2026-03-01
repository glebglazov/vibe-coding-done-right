import Foundation
import Testing
@testable import vcdr

// MARK: - OutputDestinationType

@Suite("OutputDestinationType")
struct OutputDestinationTypeTests {

    @Test("userCreatable contains only bashScript")
    func userCreatable() {
        #expect(OutputDestinationType.userCreatable == [.bashScript])
    }

    @Test(
        "displayName returns human-readable string for each type",
        arguments: [
            (OutputDestinationType.paste, "Paste (Cmd+V)"),
            (OutputDestinationType.bashScript, "Bash Script"),
            (OutputDestinationType.outputPanel, "Output Panel"),
        ]
    )
    func displayName(type: OutputDestinationType, expected: String) {
        #expect(type.displayName == expected)
    }
}

// MARK: - OutputDestination

@Suite("OutputDestination")
struct OutputDestinationTests {

    @Test("Paste destination is built-in")
    func pasteIsBuiltIn() {
        let dest = OutputDestination.makeDefaultPaste()
        #expect(dest.isBuiltIn == true)
    }

    @Test("Output Panel destination is built-in")
    func outputPanelIsBuiltIn() {
        let dest = OutputDestination.makeDefaultOutputPanel()
        #expect(dest.isBuiltIn == true)
    }

    @Test("Bash Script destination is not built-in")
    func bashScriptIsNotBuiltIn() {
        let dest = OutputDestination.makeNewBashScript()
        #expect(dest.isBuiltIn == false)
    }

    @Test("makeDefaultPaste uses well-known ID and correct fields")
    func defaultPasteFactory() {
        let dest = OutputDestination.makeDefaultPaste()
        #expect(dest.id == OutputDestination.builtInPasteID)
        #expect(dest.name == "Paste")
        #expect(dest.type == .paste)
        #expect(dest.bashCommand == "")
        #expect(dest.activationKey == "p")
    }

    @Test("makeDefaultOutputPanel uses well-known ID and correct fields")
    func defaultOutputPanelFactory() {
        let dest = OutputDestination.makeDefaultOutputPanel()
        #expect(dest.id == OutputDestination.builtInOutputPanelID)
        #expect(dest.name == "Output Panel")
        #expect(dest.type == .outputPanel)
        #expect(dest.bashCommand == "")
        #expect(dest.activationKey == "o")
    }

    @Test("makeNewBashScript creates unique IDs on each call")
    func bashScriptFactoryUniqueIDs() {
        let a = OutputDestination.makeNewBashScript()
        let b = OutputDestination.makeNewBashScript()
        #expect(a.id != b.id)
    }

    @Test("makeNewBashScript uses provided name")
    func bashScriptFactoryCustomName() {
        let dest = OutputDestination.makeNewBashScript(name: "My Script")
        #expect(dest.name == "My Script")
        #expect(dest.type == .bashScript)
        #expect(dest.bashCommand == "echo $VCDR_TEXT")
        #expect(dest.activationKey == "")
    }

    @Test("makeNewBashScript defaults name to 'New Destination'")
    func bashScriptFactoryDefaultName() {
        let dest = OutputDestination.makeNewBashScript()
        #expect(dest.name == "New Destination")
    }

    @Test("Round-trips through encode/decode preserving all fields")
    func codableRoundTrip() throws {
        let original = OutputDestination.makeDefaultPaste()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OutputDestination.self, from: data)
        #expect(decoded == original)
    }

    @Test("Well-known Paste and Output Panel IDs are distinct")
    func wellKnownIDsDistinct() {
        #expect(OutputDestination.builtInPasteID != OutputDestination.builtInOutputPanelID)
    }
}
