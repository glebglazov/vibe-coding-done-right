import Testing
import Foundation
@testable import vcdr_ios

/// Tests for the default/session split exposed via DefaultSettings +
/// SettingOverrides. StyleSettings.defaultStyle is a read-only convenience
/// over the same storage.
@Suite("StyleSettings Tests")
struct StyleSettingsTests {

    @Test("Default style is casual when no value stored")
    func defaultStyleIsCasual() {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            #expect(StyleSettings.defaultStyle == .casual)
        }
    }

    @Test("DefaultSettings.setTextStyle persists")
    func canSetFormalAsDefault() {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            DefaultSettings.setTextStyle(.formal)
            #expect(StyleSettings.defaultStyle == .formal)
        }
    }

    @Test("Default style model returns correct style")
    func defaultStyleModelReturnsCorrectStyle() {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            DefaultSettings.setTextStyle(.casual)
            #expect(StyleSettings.defaultStyleModel.id == Style.casualID)

            DefaultSettings.setTextStyle(.messaging)
            #expect(StyleSettings.defaultStyleModel.id == Style.messagingID)

            DefaultSettings.setTextStyle(.formal)
            #expect(StyleSettings.defaultStyleModel.id == Style.formalID)
        }
    }

    @Test("TextStyle enum has correct display names")
    func textStyleDisplayNames() {
        #expect(TextStyle.casual.displayName == "Casual")
        #expect(TextStyle.messaging.displayName == "Messaging")
        #expect(TextStyle.formal.displayName == "Formal")
    }

    @Test("TextStyle returns correct Style model")
    func textStyleReturnsCorrectModel() {
        #expect(TextStyle.casual.style.id == Style.casualID)
        #expect(TextStyle.messaging.style.id == Style.messagingID)
        #expect(TextStyle.formal.style.id == Style.formalID)
    }

    @Test("TextStyle init from Style returns correct value")
    func textStyleInitFromStyle() {
        let casual = TextStyle(style: Style.casual)
        #expect(casual == .casual)

        let messaging = TextStyle(style: Style.messaging)
        #expect(messaging == .messaging)

        let formal = TextStyle(style: Style.formal)
        #expect(formal == .formal)
    }

    @Test("TextStyle defaults to casual for unknown style")
    func textStyleDefaultsToCasualForUnknown() {
        let unknownStyle = Style(
            id: UUID(),
            name: "Unknown",
            isBuiltIn: false,
            isDefault: false,
            staticRules: .casual
        )

        let result = TextStyle(style: unknownStyle)
        #expect(result == .casual)
    }

    @Test("Setting default clears the Setting Override")
    func defaultClearsSession() {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            // Establish a Setting Override, then change the default — the override
            // should drop so the new default wins immediately.
            DefaultSettings.setTextStyle(.casual)
            SettingOverrides.setTextStyle(.formal)
            #expect(SettingOverrides.effectiveTextStyle() == .formal)

            DefaultSettings.setTextStyle(.messaging)
            #expect(SettingOverrides.effectiveTextStyle() == .messaging)
        }
    }

    @Test("Setting Override wins over default")
    func sessionBeatsDefault() {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            DefaultSettings.setTextStyle(.casual)
            SettingOverrides.setTextStyle(.formal)
            #expect(SettingOverrides.effectiveTextStyle() == .formal)

            // Reading default directly still shows the configured default —
            // confirms the two tiers are stored separately.
            #expect(StyleSettings.defaultStyle == .casual)
        }
    }

    @Test("SettingOverrides.clearAll drops overrides")
    func clearAllDropsSession() {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            DefaultSettings.setTextStyle(.messaging)
            SettingOverrides.setTextStyle(.formal)
            #expect(SettingOverrides.effectiveTextStyle() == .formal)

            SettingOverrides.clearAll()
            #expect(SettingOverrides.effectiveTextStyle() == .messaging)
        }
    }
}
