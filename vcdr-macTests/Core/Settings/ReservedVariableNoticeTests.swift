import Foundation
import Testing
@testable import vcdr_mac

@MainActor
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
}

@Suite("Reserved Variable override notice")
@MainActor
struct ReservedVariableNoticeTests {

    @Test("Reserved Variable equal to the provider key is flagged as a safe-to-delete duplicate")
    func duplicateOfProviderKey() {
        let settings = AppSettings(userDefaults: makeDefaults())
        settings.setAPIKey("sk-provider", for: .anthropic)

        let variable = Variable(name: "ANTHROPIC_API_KEY", value: "sk-provider")
        #expect(settings.reservedVariableNotice(for: variable) == .duplicatesProviderKey(provider: .anthropic))
        #expect(settings.reservedVariableNotice(for: variable)?.message.contains("safe to delete") == true)
    }

    @Test("Reserved Variable differing from the provider key warns it is bash-only")
    func divergentOverride() {
        let settings = AppSettings(userDefaults: makeDefaults())
        settings.setAPIKey("sk-provider", for: .anthropic)

        let variable = Variable(name: "ANTHROPIC_API_KEY", value: "sk-bash-override")
        let notice = settings.reservedVariableNotice(for: variable)
        #expect(notice == .overridesBashOnly(provider: .anthropic))
        #expect(notice?.isWarning == true)
        #expect(notice?.message.contains("bash scripts only") == true)
    }

    @Test("Empty Reserved Variable produces a no-effect fallback notice, not a warning")
    func emptyOverride() {
        let settings = AppSettings(userDefaults: makeDefaults())
        settings.setAPIKey("sk-provider", for: .openai)

        let variable = Variable(name: "OPENAI_API_KEY", value: "")
        let notice = settings.reservedVariableNotice(for: variable)
        #expect(notice == .noEffect(provider: .openai))
        #expect(notice?.isWarning == false)
    }

    @Test("Non-reserved Variable has no notice")
    func nonReservedHasNoNotice() {
        let settings = AppSettings(userDefaults: makeDefaults())
        settings.setAPIKey("sk-provider", for: .anthropic)

        #expect(settings.reservedVariableNotice(for: Variable(name: "MY_VAR", value: "x")) == nil)
        #expect(settings.reservedVariableNotice(for: Variable(name: "MY_VAR", value: "")) == nil)
    }
}
