import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

struct RecordingRunOriginTests {
    @Test("each origin delivers to exactly its own destination")
    func delivery() {
        #expect(RecordingRunOrigin.keyboard.deliversToKeyboard)
        #expect(!RecordingRunOrigin.app.deliversToKeyboard)
        #expect(!RecordingRunOrigin.shortcut.deliversToKeyboard)
    }

    @Test("only a Shortcut run shows its outcome on the card")
    func cardOutcome() {
        #expect(RecordingRunOrigin.shortcut.showsOutcomeOnCard)
        #expect(!RecordingRunOrigin.app.showsOutcomeOnCard)
        #expect(!RecordingRunOrigin.keyboard.showsOutcomeOnCard)
    }

    @Test("only a Shortcut run cannot be stopped from the card")
    func cardStop() {
        #expect(!RecordingRunOrigin.shortcut.stopsFromCard)
        #expect(RecordingRunOrigin.app.stopsFromCard)
        #expect(RecordingRunOrigin.keyboard.stopsFromCard)
    }

    @Test("only a Shortcut run keeps its card while VCDR is on screen")
    func foregroundCard() {
        #expect(RecordingRunOrigin.shortcut.keepsCardInForeground)
        #expect(!RecordingRunOrigin.app.keepsCardInForeground)
        #expect(!RecordingRunOrigin.keyboard.keepsCardInForeground)
    }
}
