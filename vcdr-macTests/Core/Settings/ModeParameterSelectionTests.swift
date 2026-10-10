import Foundation
import Testing
@testable import vcdr_mac

@Suite("Mode parameter selection")
@MainActor
struct ModeParameterSelectionTests {
    @Test("Cloud providers and None never show local model choices", arguments: AIProvider.allCases)
    func cloudSwitches(provider: AIProvider) throws {
        var mode = ModeTemplate.claudeCode.makeMode()
        let localParameters = mode.parameters
        for _ in 0..<3 {
            mode.processingType = .cloudAI
            mode.aiProvider = provider
            #expect(mode.parameters.isEmpty)
            #expect(mode.defaultParameterLabels == nil)
            mode.processingType = .none
            #expect(mode.parameters.isEmpty)
            mode.processingType = .localAgent
            #expect(mode.parameters == localParameters)
        }
    }

    @Test("Saved Cloud AI Modes discard stale Haiku labels", arguments: AIProvider.allCases)
    func staleCloudMode(provider: AIProvider) throws {
        let legacy = try savedMode(type: .cloudAI, parameters: ModeTemplate.claudeCode.parameters, provider: provider)
        let mode = try JSONDecoder().decode(Mode.self, from: legacy)
        #expect(mode.defaultParameterLabels == nil)
        #expect(mode.parameters.isEmpty)
        let reloaded = try roundTrip(mode)
        #expect(reloaded.parameters.isEmpty)
    }

    @Test("Bash Script parameters survive provider switches and restart")
    func scriptParametersSurvive() throws {
        let custom = ModeTemplate.ollama.parameters
        var mode = Mode(id: UUID(), name: "Custom", processingType: .bashScript, parameters: custom)
        mode.processingType = .localAgent
        #expect(mode.defaultParameterLabels == "Haiku")
        let local = mode.parameters
        mode.processingType = .cloudAI
        mode.aiProvider = .gemini
        mode = try roundTrip(mode)
        #expect(mode.parameters.isEmpty)
        mode.processingType = .localAgent
        #expect(mode.parameters == local)
        mode.processingType = .bashScript
        #expect(mode.parameters == custom)
        mode.parameters[0].options.reverse()
        let edited = mode.parameters
        mode.processingType = .none
        mode = try roundTrip(mode)
        mode.processingType = .bashScript
        #expect(mode.parameters == edited)
    }

    @Test("Local parameter IDs keep Session Overrides through switches and restart")
    func stableSessionOverrides() throws {
        var mode = Mode(id: UUID(), name: "Local", processingType: .localAgent)
        let parameter = try #require(mode.parameters.first)
        let overrides = SessionOverrides()
        overrides.parameterOverrides[parameter.id] = "sonnet"
        #expect(overrides.resolvedParameterLabels(for: mode) == "Sonnet")
        mode.processingType = .cloudAI
        #expect(overrides.resolvedParameterValues(for: mode).isEmpty)
        mode = try roundTrip(mode)
        mode.processingType = .localAgent
        #expect(mode.parameters.first?.id == parameter.id)
        #expect(overrides.resolvedParameterLabels(for: mode) == "Sonnet")
        #expect(overrides.resolvedParameterValues(for: mode) == ["MODEL": "sonnet"])
    }

    @Test("Legacy script and local parameters retain IDs and option order", arguments: [ProcessingType.bashScript, .localAgent])
    func legacyParameters(type: ProcessingType) throws {
        var parameters = ModeTemplate.claudeCode.parameters
        parameters[0].options.reverse()
        var mode = try JSONDecoder().decode(Mode.self, from: savedMode(type: type, parameters: parameters))
        #expect(mode.parameters == parameters)
        mode.processingType = .cloudAI
        mode = try roundTrip(mode)
        mode.processingType = type
        #expect(mode.parameters == parameters)
    }

    @Test("Empty saved local parameters receive stable defaults")
    func emptyLegacyLocal() throws {
        let mode = try JSONDecoder().decode(Mode.self, from: savedMode(type: .localAgent, parameters: []))
        #expect(mode.defaultParameterLabels == "Haiku")
        #expect(try roundTrip(mode) == mode)
    }

    @Test("New parameter banks take precedence over legacy active parameters")
    func newBanksTakePrecedence() throws {
        let legacy = try savedMode(type: .bashScript, parameters: ModeTemplate.ollama.parameters)
        var json = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        json["bashScriptParameters"] = []
        json["localAgentParameters"] = []
        var mode = try JSONDecoder().decode(Mode.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(mode.parameters.isEmpty)
        mode.processingType = .localAgent
        #expect(mode.defaultParameterLabels == "Haiku")
    }

    @Test("Template reset clears inactive parameters without changing preserved fields", arguments: ModeTemplate.all.map(\.id))
    func resetParameters(templateID: String) throws {
        let template = try #require(ModeTemplate.template(for: templateID))
        var mode = template.makeMode()
        let id = mode.id
        mode.isDisabled = true
        mode.saveResultToClipboard = true
        mode.processingType = .bashScript
        mode.parameters = [ModeParameter(id: UUID(), name: "Custom", options: [])]
        mode.processingType = .localAgent
        mode.parameters = [ModeParameter(id: UUID(), name: "Other", options: [])]
        template.resetMode(&mode)
        #expect(mode.id == id)
        #expect(mode.isDisabled)
        #expect(mode.templateID == templateID)
        #expect(mode.saveResultToClipboard)
        #expect(mode.parameters == template.parameters)
        mode = try roundTrip(mode)
        mode.processingType = .bashScript
        #expect(mode.parameters == (template.processingType == .bashScript ? template.parameters : []))
        mode.processingType = .localAgent
        if template.processingType == .localAgent {
            #expect(mode.parameters == template.parameters)
        } else {
            #expect(mode.defaultParameterLabels == "Haiku")
        }
    }

    private func roundTrip(_ mode: Mode) throws -> Mode {
        try JSONDecoder().decode(Mode.self, from: JSONEncoder().encode(mode))
    }

    private func savedMode(type: ProcessingType, parameters: [ModeParameter], provider: AIProvider = .gemini) throws -> Data {
        let encodedParameters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters))
        return try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "name": "Saved",
            "processingType": type.rawValue,
            "aiProvider": provider.rawValue,
            "parameters": encodedParameters,
        ])
    }
}
