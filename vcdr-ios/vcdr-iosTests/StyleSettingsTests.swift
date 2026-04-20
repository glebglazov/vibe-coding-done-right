import Testing
import Foundation
@testable import vcdr_ios

/// Tests for the default/session split exposed via DefaultSettings +
/// SessionSettings. StyleSettings.defaultStyle is a read-only convenience
/// over the same storage.
@Suite("StyleSettings Tests")
struct StyleSettingsTests {

    /// Resets the style-related slots in `sharedDefaults` so tests start from
    /// a known state. Restore afterwards to avoid leaking between suites.
    private static func clearStyleSlots() {
        let sd = SharedConstants.sharedDefaults
        sd.removeObject(forKey: SharedConstants.defaultTextStyleKey)
        sd.removeObject(forKey: SharedConstants.sessionTextStyleKey)
    }

    @Test("Default style is casual when no value stored")
    func defaultStyleIsCasual() {
        let original = StyleSettings.defaultStyle
        Self.clearStyleSlots()
        defer { DefaultSettings.setTextStyle(original) }

        #expect(StyleSettings.defaultStyle == .casual)
    }

    @Test("DefaultSettings.setTextStyle persists")
    func canSetFormalAsDefault() {
        let original = StyleSettings.defaultStyle
        defer { DefaultSettings.setTextStyle(original) }

        DefaultSettings.setTextStyle(.formal)
        #expect(StyleSettings.defaultStyle == .formal)
    }

    @Test("Default style model returns correct style")
    func defaultStyleModelReturnsCorrectStyle() {
        let original = StyleSettings.defaultStyle
        defer { DefaultSettings.setTextStyle(original) }

        DefaultSettings.setTextStyle(.casual)
        #expect(StyleSettings.defaultStyleModel.id == Style.casualID)

        DefaultSettings.setTextStyle(.messaging)
        #expect(StyleSettings.defaultStyleModel.id == Style.messagingID)

        DefaultSettings.setTextStyle(.formal)
        #expect(StyleSettings.defaultStyleModel.id == Style.formalID)
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

    @Test("Setting default clears session override")
    func defaultClearsSession() {
        let original = StyleSettings.defaultStyle
        defer { DefaultSettings.setTextStyle(original); SessionSettings.clearAll() }

        // Establish a session override, then change the default — session
        // should drop so the new default wins immediately.
        DefaultSettings.setTextStyle(.casual)
        SessionSettings.setTextStyle(.formal)
        #expect(SessionSettings.effectiveTextStyle() == .formal)

        DefaultSettings.setTextStyle(.messaging)
        #expect(SessionSettings.effectiveTextStyle() == .messaging)
    }

    @Test("Session override wins over default")
    func sessionBeatsDefault() {
        let original = StyleSettings.defaultStyle
        defer { DefaultSettings.setTextStyle(original); SessionSettings.clearAll() }

        DefaultSettings.setTextStyle(.casual)
        SessionSettings.setTextStyle(.formal)
        #expect(SessionSettings.effectiveTextStyle() == .formal)

        // Reading default directly still shows the configured default —
        // confirms the two tiers are stored separately.
        #expect(StyleSettings.defaultStyle == .casual)
    }

    @Test("SessionSettings.clearAll drops overrides")
    func clearAllDropsSession() {
        let original = StyleSettings.defaultStyle
        defer { DefaultSettings.setTextStyle(original); SessionSettings.clearAll() }

        DefaultSettings.setTextStyle(.messaging)
        SessionSettings.setTextStyle(.formal)
        #expect(SessionSettings.effectiveTextStyle() == .formal)

        SessionSettings.clearAll()
        #expect(SessionSettings.effectiveTextStyle() == .messaging)
    }
}
