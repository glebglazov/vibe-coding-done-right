import Testing
import Foundation
@testable import vcdr_ios

/// Tests for StyleSettings — UserDefaults persistence
@Suite("StyleSettings Tests")
struct StyleSettingsTests {
    
    let testDefaults = UserDefaults(suiteName: "test.style.settings")!
    
    init() {
        // Clear test defaults before each test
        testDefaults.removeObject(forKey: StyleSettings.defaultStyleKey)
    }
    
    @Test("Default style is casual on fresh install")
    func defaultStyleIsCasual() {
        // Ensure no value is set
        UserDefaults.standard.removeObject(forKey: StyleSettings.defaultStyleKey)
        
        let style = StyleSettings.defaultStyle
        #expect(style == .casual)
    }
    
    @Test("Can set and read formal as default")
    func canSetFormalAsDefault() {
        let original = StyleSettings.defaultStyle
        
        StyleSettings.defaultStyle = .formal
        let result = StyleSettings.defaultStyle
        
        #expect(result == .formal)
        
        // Restore
        StyleSettings.defaultStyle = original
    }
    
    @Test("Default style model returns correct style")
    func defaultStyleModelReturnsCorrectStyle() {
        StyleSettings.defaultStyle = .casual
        #expect(StyleSettings.defaultStyleModel.id == Style.casualID)
        
        StyleSettings.defaultStyle = .formal
        #expect(StyleSettings.defaultStyleModel.id == Style.formalID)
    }
    
    @Test("TextStyle enum has correct display names")
    func textStyleDisplayNames() {
        #expect(TextStyle.casual.displayName == "Casual")
        #expect(TextStyle.formal.displayName == "Formal")
    }
    
    @Test("TextStyle returns correct Style model")
    func textStyleReturnsCorrectModel() {
        #expect(TextStyle.casual.style.id == Style.casualID)
        #expect(TextStyle.formal.style.id == Style.formalID)
    }
    
    @Test("TextStyle init from Style returns correct value")
    func textStyleInitFromStyle() {
        let casual = TextStyle(style: Style.casual)
        #expect(casual == .casual)
        
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
    
    @Test("Persistence across reads")
    func persistenceAcrossReads() {
        // Save original
        let original = StyleSettings.defaultStyle
        
        // Set to formal
        StyleSettings.defaultStyle = .formal
        
        // Multiple reads should return the same value
        #expect(StyleSettings.defaultStyle == .formal)
        #expect(StyleSettings.defaultStyle == .formal)
        
        // Restore to original
        StyleSettings.defaultStyle = original
    }
}