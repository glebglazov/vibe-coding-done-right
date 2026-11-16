import Foundation

/// Final, deterministic shaping of transcribed text before delivery:
/// applies the static style rules (capitalization, ending punctuation) and the
/// trailing terminator. Pure; no side effects.
enum TranscriptFinalizer {
    /// - Parameters:
    ///   - text: filler-cleaned transcript, or AI-processed output.
    ///   - style: the text style whose static rules + terminator policy apply.
    static func finalize(_ text: String, style: TextStyle) -> String {
        let styled = StyleTransformer.transform(text, using: style.style.staticRules)
        return TextPostProcessor.applyTerminator(to: styled, style: style.style)
    }
}
