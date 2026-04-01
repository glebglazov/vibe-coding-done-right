import Foundation

/// Removes filler words (um, uh, hmm, etc.) from transcribed text.
/// Handles comma-wrapped fillers and cleans up resulting whitespace/capitalization.
enum FillerWordRemover {

    // MARK: - Filler Words by Language

    /// English: um, uh, hmm, mm, mhm, erm, er, ah
    private static let englishFillers = #"u+m+|u+h+|h+m+m+|m{2,}|m+h+m+|e+r+m+|er|a+h+"#

    /// Russian: эм, э
    private static let russianFillers = #"э+м+|э+"#

    // MARK: - Compiled Patterns

    private static let fillerAlternatives = [englishFillers, russianFillers].joined(separator: "|")

    /// Comma-wrapped filler before a capitalized word — likely a sentence boundary.
    /// Replaces with ". " to preserve the implied sentence break.
    /// Uses \p{Lu}\p{Ll} (uppercase + lowercase) so the lookahead works across scripts.
    /// Excludes standalone "I" which is always uppercase but rarely starts a new sentence after a filler.
    private static let sentenceBoundaryFillerPattern = #"(?i),\s*\b(?:"# + fillerAlternatives + #")\b\s*,(?=\s*(?-i:\p{Lu}\p{Ll}))"#

    private static let sentenceBoundaryFillerRegex = try! Regex(sentenceBoundaryFillerPattern)

    /// General pattern matching filler words with optional surrounding commas.
    /// Allows repeated characters (e.g. "ummm", "hmmm", "uhhh", "ээм").
    /// Word boundaries prevent matching substrings (e.g. "umbrella", "это").
    private static let fillerPattern = #"(?i),?\s*\b(?:"# + fillerAlternatives + #")\b\s*,?"#

    private static let fillerRegex = try! Regex(fillerPattern)

    /// Removes filler words from the given text and cleans up punctuation/capitalization.
    static func remove(from text: String) -> String {
        // First pass: comma-wrapped fillers before uppercase → period (sentence boundary)
        var result = text.replacing(sentenceBoundaryFillerRegex, with: ". ")

        // Second pass: remaining fillers → space
        result = result.replacing(fillerRegex, with: " ")

        // Collapse multiple spaces to single space
        result = result.replacing(#/\s{2,}/#, with: " ")

        // Remove space before punctuation (". " from removed filler)
        result = result.replacing(#/ ([.!?,])/#, with: { match in
            String(match.output.1)
        })

        // Collapse repeated sentence-ending punctuation (e.g. ".." from "Something. Um." removal)
        result = result.replacing(#/([.!?])\1+/#, with: { match in
            String(match.output.1)
        })

        // Capitalize first letter after sentence-ending punctuation
        result = result.replacing(#/([.!?])\s+([a-z])/#, with: { match in
            "\(match.output.1) \(match.output.2.uppercased())"
        })

        result = result.trimmingCharacters(in: .whitespaces)

        // Remove orphaned punctuation left after filler removal (e.g. "Um." → ".")
        result = result.replacing(#/^[.!?,\s]+$/#, with: "")

        // Capitalize first character
        if let first = result.first, first.isLetter && first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }
}
