import Testing
import Foundation
@testable import vcdr_ios

/// Tests for StyleSessionState in RecordingFlowCoordinator
@Suite("StyleSessionState Tests")
struct StyleSessionStateTests {
    
    @Test("Coordinator initializes with default style from settings")
    @MainActor
    func coordinatorInitializesWithDefaultStyle() async throws {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            DefaultSettings.setTextStyle(.formal)
            SessionSettings.clearAll()

            let coordinator = RecordingFlowCoordinator(presence: SpyMicPresenceCard())
            #expect(coordinator.currentTextStyle == .formal)
        }
    }

    @Test("Coordinator defaults to casual when settings undefined")
    @MainActor
    func coordinatorDefaultsToCasual() async throws {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.defaultTextStyleKey)
            SessionSettings.clearAll()

            let coordinator = RecordingFlowCoordinator(presence: SpyMicPresenceCard())
            #expect(coordinator.currentTextStyle == .casual)
        }
    }

    @Test("Session override survives scene background")
    @MainActor
    func sessionSurvivesBackground() async throws {
        SharedSettingsTestIsolation.withCleanStyleSlots {
            // User has "Casual" as default, then cycles to Messaging in-session.
            // No syncAll or other broadcast should be able to revert that without
            // someone explicitly calling SessionSettings.clearAll() or the user
            // changing the default.
            DefaultSettings.setTextStyle(.casual)
            SessionSettings.setTextStyle(.messaging)
            #expect(SessionSettings.effectiveTextStyle() == .messaging)

            // Simulate whatever the app might still do on background: the only
            // settings-writing API available is DefaultSettings.setAIConfigured,
            // which must not touch session_text_style.
            DefaultSettings.setAIConfigured(true)
            #expect(SessionSettings.effectiveTextStyle() == .messaging)
        }
    }
    
    @Test("Can toggle style during session")
    @MainActor
    func canToggleStyleDuringSession() async throws {
        let coordinator = RecordingFlowCoordinator(presence: SpyMicPresenceCard())
        
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

        let messaging = Style.messaging
        #expect(messaging.staticRules.capitalizeSentences == true)
        #expect(messaging.staticRules.endingPunctuation == .removeFinalDot)

        let formal = Style.formal
        #expect(formal.staticRules.capitalizeSentences == true)
        #expect(formal.staticRules.endingPunctuation == .addIfAbsent)
    }

    @Test("Style IDs are stable")
    func styleIDsAreStable() {
        // These UUIDs should never change (used for persistence)
        let expectedCasualID = UUID(uuidString: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")!
        let expectedMessagingID = UUID(uuidString: "C3D4E5F6-A7B8-4C9D-AE1F-2A3B4C5D6E7F")!
        let expectedFormalID = UUID(uuidString: "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E")!

        #expect(Style.casualID == expectedCasualID)
        #expect(Style.messagingID == expectedMessagingID)
        #expect(Style.formalID == expectedFormalID)
        #expect(Style.casual.id == expectedCasualID)
        #expect(Style.messaging.id == expectedMessagingID)
        #expect(Style.formal.id == expectedFormalID)
    }

    @Test("Built-in styles are correctly marked")
    func builtInStylesAreMarked() {
        #expect(Style.casual.isBuiltIn == true)
        #expect(Style.messaging.isBuiltIn == true)
        #expect(Style.formal.isBuiltIn == true)

        #expect(Style.casual.name == "Casual")
        #expect(Style.messaging.name == "Messaging")
        #expect(Style.formal.name == "Formal")
    }

    @Test("Built-in array contains expected styles in order: casual, messaging, formal")
    func builtInArrayContents() {
        let builtIn = Style.builtIn

        #expect(builtIn.count == 3)
        #expect(builtIn[0].id == Style.casualID)
        #expect(builtIn[1].id == Style.messagingID)
        #expect(builtIn[2].id == Style.formalID)
    }

    // MARK: - appliesStyles Tests

    @Test("Dictation mode applies styles")
    func dictationModeAppliesStyles() {
        #expect(AIPromptMode.dictation.appliesStyles == true)
    }

    @Test("Assistant mode does not apply styles")
    func assistantModeDoesNotApplyStyles() {
        #expect(AIPromptMode.assistant.appliesStyles == false)
    }
}
