import Testing
import Foundation
@testable import vcdr_ios

/// Tests for StyleSessionState in RecordingFlowCoordinator
@Suite("StyleSessionState Tests")
struct StyleSessionStateTests {
    
    @Test("Coordinator initializes with default style from settings")
    @MainActor
    func coordinatorInitializesWithDefaultStyle() async throws {
        // Save current default
        let originalDefault = StyleSettings.defaultStyle
        
        // Set formal as default
        StyleSettings.defaultStyle = .formal
        
        // Create a new coordinator
        let coordinator = RecordingFlowCoordinator()
        
        #expect(coordinator.currentTextStyle == .formal)
        
        // Restore
        StyleSettings.defaultStyle = originalDefault
    }
    
    @Test("Coordinator defaults to casual when settings undefined")
    @MainActor
    func coordinatorDefaultsToCasual() async throws {
        // Clear the setting
        let original = StyleSettings.defaultStyle
        UserDefaults.standard.removeObject(forKey: StyleSettings.defaultStyleKey)
        
        let coordinator = RecordingFlowCoordinator()
        
        #expect(coordinator.currentTextStyle == .casual)
        
        // Restore
        StyleSettings.defaultStyle = original
    }
    
    @Test("Can toggle style during session")
    @MainActor
    func canToggleStyleDuringSession() async throws {
        let coordinator = RecordingFlowCoordinator()
        
        // Start with casual
        coordinator.currentTextStyle = .casual
        #expect(coordinator.currentTextStyle == .casual)
        
        // Toggle to formal
        coordinator.currentTextStyle = .formal
        #expect(coordinator.currentTextStyle == .formal)
        
        // Toggle back to casual
        coordinator.currentTextStyle = .casual
        #expect(coordinator.currentTextStyle == .casual)
    }
    
    @Test("Style model has correct static rules")
    func styleModelHasCorrectRules() {
        let casual = Style.casual
        #expect(casual.staticRules.capitalizeSentences == false)
        #expect(casual.staticRules.endingPunctuation == .removeFinalDot)
        
        let formal = Style.formal
        #expect(formal.staticRules.capitalizeSentences == true)
        #expect(formal.staticRules.endingPunctuation == .addIfAbsent)
    }
    
    @Test("Style IDs are stable")
    func styleIDsAreStable() {
        // These UUIDs should never change (used for persistence)
        let expectedCasualID = UUID(uuidString: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")!
        let expectedFormalID = UUID(uuidString: "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E")!
        
        #expect(Style.casualID == expectedCasualID)
        #expect(Style.formalID == expectedFormalID)
        #expect(Style.casual.id == expectedCasualID)
        #expect(Style.formal.id == expectedFormalID)
    }
    
    @Test("Built-in styles are correctly marked")
    func builtInStylesAreMarked() {
        #expect(Style.casual.isBuiltIn == true)
        #expect(Style.formal.isBuiltIn == true)
        
        #expect(Style.casual.name == "Casual")
        #expect(Style.formal.name == "Formal")
    }
    
    @Test("Built-in array contains expected styles")
    func builtInArrayContents() {
        let builtIn = Style.builtIn
        
        #expect(builtIn.count == 2)
        #expect(builtIn[0].id == Style.casualID)
        #expect(builtIn[1].id == Style.formalID)
    }
}