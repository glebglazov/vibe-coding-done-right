import Foundation

/// Applies filler word removal and terminator to transcribed text.
/// Each stage can be called independently so the coordinator can run
/// the terminator after external processing (matching the macOS pipeline).
enum TextPostProcessor {
    private static let sentenceEndingPunctuation: Set<Character> = [".", "?", "!"]

    /// Removes filler words only — no terminator.
    static func removeFillers(from text: String) -> String {
        FillerWordRemover.remove(from: text)
    }

    /// Appends spacing (terminator) to the text.
    /// Always adds a trailing space so the user can continue typing/dictating.
    /// If the text doesn't end with punctuation, adds ". " for formal style compatibility.
    static func applyTerminator(to text: String, style: Style? = nil) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return text }

        // If text already ends with sentence-ending punctuation, just add space
        if sentenceEndingPunctuation.contains(last) {
            return trimmed + " "
        }

        // For formal style, add period + space since StyleTransformer would have added period
        // For casual style, just add space (no period)
        if let style = style, style.staticRules.endingPunctuation == .addIfAbsent {
            return trimmed + ". "
        }

        // Casual style or no style specified - just add space
        return trimmed + " "
    }

    /// Full pipeline: filler removal + terminator. Convenience for callers
    /// that don't need to insert external processing between stages.
    static func process(_ text: String) -> String {
        applyTerminator(to: removeFillers(from: text))
    }
}
