import Foundation

/// Removes filler words (um, uh, hmm, etc.) from transcribed text.
/// Handles comma-wrapped fillers and cleans up resulting whitespace/capitalization.
enum FillerWordRemover {

    // MARK: - Constants

    /// Pattern matching filler words with optional surrounding commas.
    /// Allows repeated characters (e.g. "ummm", "hmmm", "uhhh").
    /// Word boundaries prevent matching substrings (e.g. "umbrella").
    private static let fillerPattern = #"(?i),?\s*\b(?:u+m+|u+h+|h+m+m+|m+h+m+|e+r+m+|er|a+h+)\b\s*,?"#

    private static let fillerRegex = try! Regex(fillerPattern)

    /// Removes filler words from the given text and cleans up punctuation/capitalization.
    static func remove(from text: String) -> String {
        var result = text.replacing(fillerRegex, with: " ")

        // Collapse multiple spaces to single space
        result = result.replacing(#/\s{2,}/#, with: " ")

        // Remove space before punctuation (". " from removed filler)
        result = result.replacing(#/ ([.!?,])/#, with: { match in
            String(match.output.1)
        })

        // Capitalize first letter after sentence-ending punctuation
        result = result.replacing(#/([.!?])\s+([a-z])/#, with: { match in
            "\(match.output.1) \(match.output.2.uppercased())"
        })

        result = result.trimmingCharacters(in: .whitespaces)

        // Capitalize first character
        if let first = result.first, first.isLetter && first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }
}
