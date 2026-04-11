import Foundation

/// Defines how ending punctuation should be handled for a style.
public enum PunctuationRule: Codable, Equatable, Sendable {
    /// Add ending punctuation (period) if the text doesn't end with `.`, `?`, or `!`.
    /// Used by the Formal style to ensure proper punctuation.
    case addIfAbsent
    
    /// Remove a final period (`.`) if present, but preserve `?` and `!`.
    /// Used by the Casual style for informal, conversational text.
    case removeFinalDot
    
    /// Leave ending punctuation exactly as-is.
    /// Available for future custom styles.
    case preserve
}
