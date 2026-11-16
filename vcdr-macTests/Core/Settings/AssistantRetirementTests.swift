import Foundation
import Testing
@testable import vcdr_mac

/// A launch after the removal of the Assistant leaves no Assistant Mode, moves
/// an active one to AI on, and keeps every other Mode. A second launch changes
/// nothing.
@MainActor
@Suite("Retired Assistant Modes")
struct AssistantRetirementTests {
    private let defaults = UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!

    private let remote = UUID()
    private let local = UUID()
    private let aiOn = UUID()
    private let aiOff = UUID()

    private func storedMode(
        _ id: UUID,
        name: String,
        templateID: String? = nil,
        processingType: String,
        promptType: String = "dictation"
    ) -> [String: Any] {
        var mode: [String: Any] = [
            "id": id.uuidString,
            "name": name,
            "processingType": processingType,
            "promptType": promptType,
        ]
        mode["templateID"] = templateID
        return mode
    }

    private var builtInModes: [[String: Any]] {
        [
            storedMode(aiOff, name: "Verbatim", templateID: "plain", processingType: "none"),
            storedMode(aiOn, name: "Dictation", templateID: "ai-dictation", processingType: "cloudAI"),
            storedMode(remote, name: "Assistant (Remote)", templateID: "claude-code", processingType: "localAgent", promptType: "assistant"),
            storedMode(local, name: "My Ollama", templateID: "ollama", processingType: "bashScript", promptType: "assistant"),
        ]
    }

    private func store(_ modes: [[String: Any]], active: UUID) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: modes), forKey: "modes")
        defaults.set(active.uuidString, forKey: "activeModeID")
    }

    /// What the app does at launch: read the settings, then make the built-in
    /// Modes. A stored Anthropic key keeps AI on in the switcher.
    private func launch() -> AppSettings {
        let settings = AppSettings(
            userDefaults: defaults,
            secretStore: InMemorySecretStore(secrets: ["ai_processing_anthropic_api_key": "sk-test"])
        )
        settings.restoreTemplateModes()
        return settings
    }

    @Test("Both Assistant template Modes are deleted, recorded as retired, and not made again")
    func templateModesRetire() throws {
        try store(builtInModes, active: aiOff)

        let settings = launch()

        #expect(Set(settings.modes.map(\.id)) == [aiOff, aiOn])
        #expect(settings.retiredModes == [
            RetiredMode(id: remote, name: "Assistant (Remote)"),
            RetiredMode(id: local, name: "My Ollama"),
        ])
    }

    @Test("A user Local Agent Mode is deleted and recorded as retired, whatever its prompt")
    func localAgentModesRetire() throws {
        let agent = UUID()
        let customAgent = UUID()
        try store(builtInModes + [
            storedMode(agent, name: "Agent", processingType: "localAgent"),
            storedMode(customAgent, name: "Translate", processingType: "localAgent", promptType: "custom"),
        ], active: customAgent)

        let settings = launch()

        #expect(Set(settings.modes.map(\.id)) == [aiOff, aiOn])
        #expect(settings.activeMode.id == aiOn)
        #expect(settings.retiredModes.suffix(2) == [
            RetiredMode(id: agent, name: "Agent"),
            RetiredMode(id: customAgent, name: "Translate"),
        ])
    }

    @Test("An active Assistant Mode becomes AI on")
    func activeRetiredModeBecomesAIOn() throws {
        try store(builtInModes, active: remote)

        #expect(launch().activeMode.id == aiOn)
    }

    @Test("An active Assistant Mode becomes a new AI on when no AI on Mode is saved")
    func activeRetiredModeMakesAIOn() throws {
        try store([builtInModes[2]], active: remote)

        let settings = launch()

        #expect(settings.activeMode.templateID == "ai-dictation")
        #expect(settings.modes.filter { $0.templateID == "ai-dictation" }.count == 1)
    }

    @Test("A user Cloud AI Mode with the Assistant prompt stays, with the Dictation prompt")
    func assistantPromptBecomesDictation() throws {
        let translate = UUID()
        try store(builtInModes + [
            storedMode(translate, name: "Shorten", processingType: "cloudAI", promptType: "assistant"),
        ], active: translate)

        let settings = launch()

        let kept = try #require(settings.modes.first { $0.id == translate })
        #expect(kept.promptType == .dictation)
        #expect(settings.activeMode.id == translate)
        #expect(!settings.retiredModes.contains { $0.id == translate })
        let stored = try #require(defaults.data(forKey: "modes"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("\"assistant\""))
    }

    @Test("A built-in Mode with an earlier default name gets the new name; a name the user chose stays")
    func builtInNames() throws {
        let legacyPlain = UUID()
        try store([
            storedMode(legacyPlain, name: "Dictation", templateID: "dictation", processingType: "none"),
            storedMode(aiOn, name: "Dictation", templateID: "ai-dictation", processingType: "cloudAI"),
        ], active: aiOn)
        let renamed = launch()
        #expect(renamed.modes.first { $0.id == legacyPlain }?.name == "AI off")
        #expect(renamed.modes.first { $0.id == aiOn }?.name == "AI on")

        try store([
            storedMode(aiOff, name: "Raw", templateID: "plain", processingType: "none"),
            storedMode(aiOn, name: "Clean up", templateID: "ai-dictation", processingType: "cloudAI"),
        ], active: aiOn)
        #expect(launch().modes.map(\.name) == ["Raw", "Clean up"])
    }

    @Test("A fresh install gets AI off and AI on only")
    func freshInstall() {
        #expect(launch().modes.map(\.name) == ["AI off", "AI on"])
    }

    @Test("The cached Assistant prompt is deleted")
    func cachedAssistantPromptGoes() throws {
        defaults.set("You are a voice-command executor.", forKey: "cachedPrompt_assistant")
        defaults.set("You clean up raw voice dictation.", forKey: "cachedPrompt_dictation")

        _ = launch()

        #expect(defaults.object(forKey: "cachedPrompt_assistant") == nil)
        #expect(defaults.string(forKey: "cachedPrompt_dictation") == "You clean up raw voice dictation.")
    }

    @Test("A second launch changes nothing")
    func secondLaunchChangesNothing() throws {
        try store(builtInModes + [
            storedMode(UUID(), name: "Shorten", processingType: "cloudAI", promptType: "assistant"),
        ], active: remote)
        let first = launch()

        let second = launch()

        #expect(second.modes == first.modes)
        #expect(second.activeModeID == first.activeModeID)
        #expect(second.retiredModes == first.retiredModes)
    }
}
