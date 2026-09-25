import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Pins which destinations and Captures each Run Origin reaches.
struct RecordingRunOriginTests {
    @Test("only a Shortcut run leaves keyboard Captures alone")
    func captures() {
        #expect(RecordingRunOrigin.app.usesKeyboardCaptures)
        #expect(RecordingRunOrigin.keyboard.usesKeyboardCaptures)
        #expect(!RecordingRunOrigin.shortcut.usesKeyboardCaptures)
    }

    @Test("each origin delivers to exactly its own destination")
    func delivery() {
        #expect(RecordingRunOrigin.keyboard.deliversToKeyboard)
        #expect(!RecordingRunOrigin.app.deliversToKeyboard)
        #expect(!RecordingRunOrigin.shortcut.deliversToKeyboard)
        #expect(RecordingRunOrigin.shortcut.deliversToClipboard)
        #expect(!RecordingRunOrigin.app.deliversToClipboard)
        #expect(!RecordingRunOrigin.keyboard.deliversToClipboard)
    }

    @Test("only a Shortcut run keeps its card while VCDR is on screen")
    func foregroundCard() {
        #expect(RecordingRunOrigin.shortcut.keepsCardInForeground)
        #expect(!RecordingRunOrigin.app.keepsCardInForeground)
        #expect(!RecordingRunOrigin.keyboard.keepsCardInForeground)
    }
}
