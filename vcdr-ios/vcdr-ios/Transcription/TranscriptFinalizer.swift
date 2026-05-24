import Foundation

/// Final, deterministic shaping of transcribed text before delivery:
/// applies the static style rules (capitalization, ending punctuation) and the
/// trailing terminator. Honors the one cross-cutting rule that AI *assistant*
/// output is delivered as-is — its phrasing is intentional and must not be
/// restyled. Pure; no side effects. The single source of truth for the recipe
/// previously inlined at three sites in RecordingFlowCoordinator.
enum TranscriptFinalizer {
    /// - Parameters:
    ///   - text: filler-cleaned transcript, or AI-processed output.
    ///   - mode: drives whether static styles apply (`mode.appliesStyles`).
    ///   - style: the text style whose static rules + terminator policy apply.
    static func finalize(_ text: String, mode: AIPromptMode, style: TextStyle) -> String {
        guard mode.appliesStyles else {
            return TextPostProcessor.applyTerminator(to: text)
        }
        let styled = StyleTransformer.transform(text, using: style.style.staticRules)
        return TextPostProcessor.applyTerminator(to: styled, style: style.style)
    }
}
