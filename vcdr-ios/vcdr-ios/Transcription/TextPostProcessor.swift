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

    /// Appends spacing (terminator) to the text. If the text ends
    /// with sentence-ending punctuation, a space is appended. Otherwise,
    /// the text is returned as-is. Period handling is done by StyleTransformer.
    static func applyTerminator(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return text }

        // Only add spacing if text already ends with punctuation.
        // Periods are added/removed by StyleTransformer based on style.
        if sentenceEndingPunctuation.contains(last) {
            return trimmed + " "
        }

        return trimmed
    }

    /// Full pipeline: filler removal + terminator. Convenience for callers
    /// that don't need to insert external processing between stages.
    static func process(_ text: String) -> String {
        applyTerminator(to: removeFillers(from: text))
    }
}
