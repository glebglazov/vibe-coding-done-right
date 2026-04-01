import Foundation

/// Applies filler word removal and terminator to transcribed text.
/// Each stage can be called independently so the coordinator can run
/// the terminator after external processing (matching the macOS pipeline).
enum TextPostProcessor {
    /// Default terminator: period followed by a space
    private static let terminatorTemplate = "<dot><space>"
    private static let sentenceEndingPunctuation: Set<Character> = [".", "?", "!"]

    /// Removes filler words only — no terminator.
    static func removeFillers(from text: String) -> String {
        FillerWordRemover.remove(from: text)
    }

    /// Appends a terminator (e.g. ". ") to the text. If the text already ends
    /// with sentence-ending punctuation, only the spacing portion is appended.
    static func applyTerminator(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.last != nil else { return text }

        let resolved = terminatorTemplate
            .replacingOccurrences(of: "<dot>", with: ".")
            .replacingOccurrences(of: "<space>", with: " ")
            .replacingOccurrences(of: "<newline>", with: "\n")

        let punctuationPrefix = String(resolved.prefix(while: { sentenceEndingPunctuation.contains($0) }))
        let spacingSuffix = String(resolved.dropFirst(punctuationPrefix.count))

        if sentenceEndingPunctuation.contains(trimmed.last!) {
            return trimmed + spacingSuffix
        }

        return trimmed + resolved
    }

    /// Full pipeline: filler removal + terminator. Convenience for callers
    /// that don't need to insert external processing between stages.
    static func process(_ text: String) -> String {
        applyTerminator(to: removeFillers(from: text))
    }
}
