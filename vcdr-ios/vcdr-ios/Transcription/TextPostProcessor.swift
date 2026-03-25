import Foundation

/// Applies filler word removal and terminator to transcribed text.
/// Hardcoded defaults — no settings UI needed for now.
enum TextPostProcessor {
    /// Default terminator: period followed by a space
    private static let terminatorTemplate = "<dot><space>"
    private static let sentenceEndingPunctuation: Set<Character> = [".", "?", "!"]

    static func process(_ text: String) -> String {
        var result = FillerWordRemover.remove(from: text)
        result = applyTerminator(result)
        return result
    }

    /// Appends a terminator (e.g. ". ") to the text. If the text already ends
    /// with sentence-ending punctuation, only the spacing portion is appended.
    private static func applyTerminator(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last else { return text }

        let resolved = terminatorTemplate
            .replacingOccurrences(of: "<dot>", with: ".")
            .replacingOccurrences(of: "<space>", with: " ")
            .replacingOccurrences(of: "<newline>", with: "\n")

        let punctuationPrefix = String(resolved.prefix(while: { sentenceEndingPunctuation.contains($0) }))
        let spacingSuffix = String(resolved.dropFirst(punctuationPrefix.count))

        if sentenceEndingPunctuation.contains(lastChar) {
            return trimmed + spacingSuffix
        }

        return trimmed + resolved
    }
}
