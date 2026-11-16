import Foundation
import Testing
@testable import vcdr_mac

@Suite("Mode parameter selection")
@MainActor
struct ModeParameterSelectionTests {
    private static let modelParameter = ModeParameter(id: UUID(), name: "Model", options: [
        ModeParameterOption(id: UUID(), label: "Small", value: "small"),
        ModeParameterOption(id: UUID(), label: "Large", value: "large"),
    ])

    @Test("Cloud providers and None never show a Bash Script's parameters", arguments: AIProvider.allCases)
    func cloudSwitches(provider: AIProvider) throws {
        var mode = Mode(id: UUID(), name: "Script", processingType: .bashScript, parameters: [Self.modelParameter])
        for _ in 0..<3 {
            mode.processingType = .cloudAI
            mode.aiProvider = provider
            #expect(mode.parameters.isEmpty)
            #expect(mode.defaultParameterLabels == nil)
            mode.processingType = .none
            #expect(mode.parameters.isEmpty)
            mode.processingType = .bashScript
            #expect(mode.parameters == [Self.modelParameter])
        }
    }

    @Test("Saved Cloud AI Modes discard stale parameter labels", arguments: AIProvider.allCases)
    func staleCloudMode(provider: AIProvider) throws {
        let legacy = try savedMode(type: .cloudAI, parameters: [Self.modelParameter], provider: provider)
        let mode = try JSONDecoder().decode(Mode.self, from: legacy)
        #expect(mode.defaultParameterLabels == nil)
        #expect(mode.parameters.isEmpty)
        let reloaded = try roundTrip(mode)
        #expect(reloaded.parameters.isEmpty)
    }

    @Test("Bash Script parameters survive provider switches and restart")
    func scriptParametersSurvive() throws {
        let custom = [Self.modelParameter]
        var mode = Mode(id: UUID(), name: "Custom", processingType: .bashScript, parameters: custom)
        mode.processingType = .cloudAI
        mode.aiProvider = .gemini
        mode = try roundTrip(mode)
        #expect(mode.parameters.isEmpty)
        mode.processingType = .bashScript
        #expect(mode.parameters == custom)
        mode.parameters[0].options.reverse()
        let edited = mode.parameters
        mode.processingType = .none
        mode = try roundTrip(mode)
        mode.processingType = .bashScript
        #expect(mode.parameters == edited)
    }

    @Test("Bash Script parameter IDs keep Session Overrides through switches and restart")
    func stableSessionOverrides() throws {
        var mode = Mode(id: UUID(), name: "Script", processingType: .bashScript, parameters: [Self.modelParameter])
        let overrides = SessionOverrides()
        overrides.parameterOverrides[Self.modelParameter.id] = "large"
        #expect(overrides.resolvedParameterLabels(for: mode) == "Large")
        mode.processingType = .cloudAI
        #expect(overrides.resolvedParameterValues(for: mode).isEmpty)
        mode = try roundTrip(mode)
        mode.processingType = .bashScript
        #expect(mode.parameters.first?.id == Self.modelParameter.id)
        #expect(overrides.resolvedParameterLabels(for: mode) == "Large")
        #expect(overrides.resolvedParameterValues(for: mode) == ["MODEL": "large"])
    }

    @Test("Legacy script parameters retain IDs and option order")
    func legacyParameters() throws {
        var parameters = [Self.modelParameter]
        parameters[0].options.reverse()
        var mode = try JSONDecoder().decode(Mode.self, from: savedMode(type: .bashScript, parameters: parameters))
        #expect(mode.parameters == parameters)
        mode.processingType = .cloudAI
        mode = try roundTrip(mode)
        mode.processingType = .bashScript
        #expect(mode.parameters == parameters)
    }

    @Test("New parameter banks take precedence over legacy active parameters")
    func newBanksTakePrecedence() throws {
        let legacy = try savedMode(type: .bashScript, parameters: [Self.modelParameter])
        var json = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        json["bashScriptParameters"] = []
        let mode = try JSONDecoder().decode(Mode.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(mode.parameters.isEmpty)
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
        template.resetMode(&mode)
        #expect(mode.id == id)
        #expect(mode.isDisabled)
        #expect(mode.templateID == templateID)
        #expect(mode.saveResultToClipboard)
        #expect(mode.parameters == template.parameters)
        mode = try roundTrip(mode)
        mode.processingType = .bashScript
        #expect(mode.parameters == (template.processingType == .bashScript ? template.parameters : []))
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
