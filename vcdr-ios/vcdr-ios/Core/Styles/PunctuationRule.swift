import Foundation

/// How to handle ending punctuation in style transformations.
public enum PunctuationRule: String, Codable, CaseIterable, Sendable {
    /// Add a period if no sentence-ending punctuation exists.
    /// Used by the Formal style.
    case addIfAbsent
    
    /// Remove a final period (but preserve ? and !).
    /// Used by the Casual style.
    case removeFinalDot
    
    /// Preserve existing punctuation as-is.
    /// Reserved for future custom styles.
    case preserve
}