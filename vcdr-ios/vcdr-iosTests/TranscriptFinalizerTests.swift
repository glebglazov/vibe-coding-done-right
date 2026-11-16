import Testing
@testable import vcdr_ios

/// The style rules and the terminator apply the same way to AI on and AI off
/// output: only the Text Style decides the result.
@Suite("TranscriptFinalizer")
struct TranscriptFinalizerTests {

    // MARK: - Plain input ("hello world")

    @Test("casual lowercases and adds a trailing space")
    func plainCasual() {
        #expect(TranscriptFinalizer.finalize("hello world", style: .casual) == "hello world ")
    }

    @Test("messaging capitalizes and adds no final dot")
    func plainMessaging() {
        #expect(TranscriptFinalizer.finalize("hello world", style: .messaging) == "Hello world ")
    }

    @Test("formal capitalizes and adds a period and a space")
    func plainFormal() {
        #expect(TranscriptFinalizer.finalize("hello world", style: .formal) == "Hello world. ")
    }

    // MARK: - Already-styled input ("Hello world."), as AI output arrives

    @Test("casual strips the capital and the final dot")
    func styledCasual() {
        #expect(TranscriptFinalizer.finalize("Hello world.", style: .casual) == "hello world ")
    }

    @Test("messaging keeps the capital and drops the final dot")
    func styledMessaging() {
        #expect(TranscriptFinalizer.finalize("Hello world.", style: .messaging) == "Hello world ")
    }

    @Test("formal keeps the capital and the period")
    func styledFormal() {
        #expect(TranscriptFinalizer.finalize("Hello world.", style: .formal) == "Hello world. ")
    }

    @Test("casual lowercases only the first letter")
    func casualFirstLetterOnly() {
        #expect(TranscriptFinalizer.finalize("Hello World", style: .casual) == "hello World ")
    }
}
