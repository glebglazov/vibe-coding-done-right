import Testing
@testable import vcdr_ios

/// Characterization of the style+terminator recipe as it exists *today*, inlined
/// at three sites in `RecordingFlowCoordinator`. These goldens pin current
/// behavior so the `TranscriptFinalizer` extraction (Phase 2) can be proven
/// behavior-preserving — and so the one deliberate change (assistant never
/// styles in the transient fast-path) is asserted consciously rather than by
/// accident.
@Suite("TranscriptFinalizer characterization")
struct TranscriptFinalizerCharacterizationTests {

    // The recipe the FINAL / RETRY sites run today: mode-gated. When the mode
    // applies styles, transform then terminate with the style; otherwise just
    // terminate (no style, no styling).
    private func finalPathToday(_ text: String, mode: AIPromptMode, style: TextStyle) -> String {
        if mode.appliesStyles {
            let styled = StyleTransformer.transform(text, using: style.style.staticRules)
            return TextPostProcessor.applyTerminator(to: styled, style: style.style)
        }
        return TextPostProcessor.applyTerminator(to: text)
    }

    // The recipe the FAST-PATH (transient display, L722) runs today: styles
    // *unconditionally*, ignoring the mode. This is the site that disagrees with
    // the final path for assistant mode and that Phase 2 intentionally aligns.
    private func fastPathToday(_ text: String, style: TextStyle) -> String {
        let styled = StyleTransformer.transform(text, using: style.style.staticRules)
        return TextPostProcessor.applyTerminator(to: styled, style: style.style)
    }

    // MARK: - Final path, plain input ("hello world")

    @Test("final/plain: verbatim+casual lowercases, trailing space")
    func finalPlainVerbatimCasual() {
        #expect(finalPathToday("hello world", mode: .verbatim, style: .casual) == "hello world ")
    }

    @Test("final/plain: verbatim+messaging capitalizes, no final dot")
    func finalPlainVerbatimMessaging() {
        #expect(finalPathToday("hello world", mode: .verbatim, style: .messaging) == "Hello world ")
    }

    @Test("final/plain: verbatim+formal capitalizes, adds period+space")
    func finalPlainVerbatimFormal() {
        #expect(finalPathToday("hello world", mode: .verbatim, style: .formal) == "Hello world. ")
    }

    @Test("final/plain: dictation+casual lowercases, trailing space")
    func finalPlainDictationCasual() {
        #expect(finalPathToday("hello world", mode: .dictation, style: .casual) == "hello world ")
    }

    @Test("final/plain: dictation+messaging capitalizes, no final dot")
    func finalPlainDictationMessaging() {
        #expect(finalPathToday("hello world", mode: .dictation, style: .messaging) == "Hello world ")
    }

    @Test("final/plain: dictation+formal capitalizes, adds period+space")
    func finalPlainDictationFormal() {
        #expect(finalPathToday("hello world", mode: .dictation, style: .formal) == "Hello world. ")
    }

    @Test("final/plain: assistant skips styles regardless of style — casual")
    func finalPlainAssistantCasual() {
        #expect(finalPathToday("hello world", mode: .assistant, style: .casual) == "hello world ")
    }

    @Test("final/plain: assistant skips styles regardless of style — messaging")
    func finalPlainAssistantMessaging() {
        #expect(finalPathToday("hello world", mode: .assistant, style: .messaging) == "hello world ")
    }

    @Test("final/plain: assistant skips styles regardless of style — formal")
    func finalPlainAssistantFormal() {
        #expect(finalPathToday("hello world", mode: .assistant, style: .formal) == "hello world ")
    }

    // MARK: - Final path, already-styled input ("Hello world.")

    @Test("final/styled: dictation+casual strips caps + final dot")
    func finalStyledDictationCasual() {
        #expect(finalPathToday("Hello world.", mode: .dictation, style: .casual) == "hello world ")
    }

    @Test("final/styled: dictation+messaging keeps caps, drops final dot")
    func finalStyledDictationMessaging() {
        #expect(finalPathToday("Hello world.", mode: .dictation, style: .messaging) == "Hello world ")
    }

    @Test("final/styled: dictation+formal keeps caps + period+space")
    func finalStyledDictationFormal() {
        #expect(finalPathToday("Hello world.", mode: .dictation, style: .formal) == "Hello world. ")
    }

    @Test("final/styled: assistant delivers as-is + terminator (period kept)")
    func finalStyledAssistant() {
        #expect(finalPathToday("Here is your summary.", mode: .assistant, style: .formal) == "Here is your summary. ")
    }

    @Test("final/styled: assistant preserves question mark + space")
    func finalStyledAssistantQuestion() {
        #expect(finalPathToday("Did that work?", mode: .assistant, style: .casual) == "Did that work? ")
    }

    // MARK: - Fast path (transient) — documents the pre-Phase-2 divergence

    // Today the fast path styles unconditionally, so an assistant-mode recording
    // with no AI configured momentarily shows STYLED text before the unstyled
    // final result overwrites it. Phase 2 aligns this with the final path
    // (assistant never styles). These goldens lock the *current* fast-path output
    // so the change is a conscious diff, not a silent regression.
    @Test("fast-path styles unconditionally — formal capitalizes + period")
    func fastPathFormalStyles() {
        #expect(fastPathToday("hello world", style: .formal) == "Hello world. ")
    }

    @Test("fast-path styles unconditionally — messaging capitalizes")
    func fastPathMessagingStyles() {
        #expect(fastPathToday("hello world", style: .messaging) == "Hello world ")
    }

    @Test("fast-path styles unconditionally — casual lowercases")
    func fastPathCasualStyles() {
        #expect(fastPathToday("Hello World", style: .casual) == "hello World ")
    }
}
