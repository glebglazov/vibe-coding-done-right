import Foundation

/// Pure function module for transforming text according to style rules.
/// No side effects, fully testable.
public enum StyleTransformer {
    
    /// Transforms the input text according to the provided static style rules.
    ///
    /// This function:
    /// 1. Detects sentence boundaries (split on punctuation + whitespace + capital letter)
    /// 2. Applies capitalization rules to the first letter of each sentence
    /// 3. Applies ending punctuation rules to the final character
    /// 4. Preserves internal capitalization (proper nouns mid-sentence unchanged)
    ///
    /// - Parameters:
    ///   - text: The input text to transform
    ///   - rules: The static style rules to apply
    /// - Returns: The transformed text
    public static func transform(_ text: String, using rules: StaticStyleRules) -> String {
        // Handle empty or whitespace-only input
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return text
        }
        
        // Extract trailing whitespace to preserve it
        let trailingWhitespace = extractTrailingWhitespace(from: text)
        let contentWithoutTrailingWhitespace = String(text.dropLast(trailingWhitespace.count))
        
        // Apply sentence boundary detection and capitalization
        var result = applyCapitalization(to: trimmed, capitalizeSentences: rules.capitalizeSentences)
        
        // Apply ending punctuation rules
        result = applyEndingPunctuation(to: result, rule: rules.endingPunctuation)
        
        // Re-attach trailing whitespace after any ending punctuation processing
        if !trailingWhitespace.isEmpty {
            // Remove any trailing whitespace that was added from trimmed text
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // Add the original trailing whitespace
            result += trailingWhitespace
        }
        
        return result
    }
    
    /// Extracts trailing whitespace from the text.
    private static func extractTrailingWhitespace(from text: String) -> String {
        let reversed = text.reversed()
        let whitespaceCount = reversed.prefix(while: { $0.isWhitespace }).count
        return String(text.suffix(whitespaceCount))
    }
    
    // MARK: - Sentence Boundary Detection & Capitalization
    
    /// Sentence boundary pattern: punctuation followed by whitespace and a word character (letter or number).
    /// Matches: ". A", "? B", "! C", ". 1", ". Ä"
    /// Uses word character \w which includes letters (including Unicode with proper handling), numbers, and underscore.
    private static let sentenceBoundaryPattern = try! NSRegularExpression(
        pattern: #"([.!?])(\s+)(\w)"#,
        options: []
    )
    
    /// Applies capitalization rules to each sentence in the text.
    /// - Parameters:
    ///   - text: The input text
    ///   - capitalizeSentences: true to capitalize, false to lowercase
    /// - Returns: Text with capitalization applied to sentence starts
    private static func applyCapitalization(to text: String, capitalizeSentences: Bool) -> String {
        guard !text.isEmpty else { return text }
        
        var result = text
        let nsRange = NSRange(result.startIndex..., in: result)
        
        // Find all sentence boundaries and collect the positions where we need to transform
        var sentenceStarts: [String.Index] = []
        
        // The first character is always a sentence start
        sentenceStarts.append(result.startIndex)
        
        // Find subsequent sentence starts using regex
        let matches = sentenceBoundaryPattern.matches(in: result, options: [], range: nsRange)
        for match in matches {
            // The third capture group is the word character that starts the new sentence
            let letterRange = match.range(at: 3)
            if let swiftRange = Range(letterRange, in: result) {
                sentenceStarts.append(swiftRange.lowerBound)
            }
        }
        
        // Apply capitalization to each sentence start (in reverse order to preserve indices)
        for index in sentenceStarts.sorted(by: >) {
            result = transformCharacter(at: index, in: result, shouldCapitalize: capitalizeSentences)
        }
        
        return result
    }
    
    /// Transforms a single character at the given index (capitalize or lowercase).
    private static func transformCharacter(
        at index: String.Index,
        in text: String,
        shouldCapitalize: Bool
    ) -> String {
        var result = text
        let char = result[index]
        
        if shouldCapitalize {
            // Capitalize: uppercase the first letter
            let uppercased = char.uppercased()
            if uppercased != String(char) {
                result.replaceSubrange(index...index, with: uppercased)
            }
        } else {
            // Lowercase: lowercase the first letter
            let lowercased = char.lowercased()
            if lowercased != String(char) {
                result.replaceSubrange(index...index, with: lowercased)
            }
        }
        
        return result
    }
    
    // MARK: - Ending Punctuation
    
    /// Applies ending punctuation rules to the text.
    /// - Parameters:
    ///   - text: The input text
    ///   - rule: The punctuation rule to apply
    /// - Returns: Text with ending punctuation adjusted
    private static func applyEndingPunctuation(to text: String, rule: PunctuationRule) -> String {
        switch rule {
        case .addIfAbsent:
            return addEndingPunctuationIfAbsent(to: text)
        case .removeFinalDot:
            return removeFinalDot(from: text)
        case .preserve:
            return text
        }
    }
    
    /// Adds a period if the text doesn't end with sentence-ending punctuation.
    /// Handles trimmed input, returns result without trailing whitespace.
    private static func addEndingPunctuationIfAbsent(to text: String) -> String {
        guard !text.isEmpty else { return text }
        
        // Check if text already ends with sentence-ending punctuation
        if let lastChar = text.last, ".!?".contains(lastChar) {
            return text
        }
        
        // Append period
        return text + "."
    }
    
    /// Removes a final period (only `.`, not `?` or `!`) from the text.
    /// Handles trimmed input, returns result without trailing whitespace.
    private static func removeFinalDot(from text: String) -> String {
        guard !text.isEmpty else { return text }
        
        // Only remove if the last character is a period (not ? or !)
        guard text.last == "." else {
            return text
        }
        
        // Remove the final period
        return String(text.dropLast())
    }
}

// MARK: - String Helpers

private extension String {
    /// Returns the suffix of the string while the predicate returns true.
    func suffix(while predicate: (Character) -> Bool) -> String {
        let reversedDrop = self.reversed().drop(while: predicate)
        let suffixStart = self.index(self.endIndex, offsetBy: -reversedDrop.count)
        return String(self[suffixStart...])
    }
}
