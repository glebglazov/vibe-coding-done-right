import Foundation

/// Static text transformation rules that apply to all mode outputs.
/// These rules are pure functions with no side effects.
public struct StaticStyleRules: Codable, Equatable, Sendable {
    /// Whether to capitalize the first letter of each sentence.
    /// - `true` for Formal style (capitalize sentences)
    /// - `false` for Casual style (lowercase sentences)
    public let capitalizeSentences: Bool
    
    /// How to handle ending punctuation.
    public let endingPunctuation: PunctuationRule
    
    /// Creates a new set of static style rules.
    /// - Parameters:
    ///   - capitalizeSentences: Whether to capitalize the first letter of each sentence
    ///   - endingPunctuation: How to handle ending punctuation
    public init(capitalizeSentences: Bool, endingPunctuation: PunctuationRule) {
        self.capitalizeSentences = capitalizeSentences
        self.endingPunctuation = endingPunctuation
    }
}

// MARK: - Built-in Rule Presets

extension StaticStyleRules {
    /// Rules for the Casual style: lowercase sentences, remove final period.
    public static let casual = StaticStyleRules(
        capitalizeSentences: false,
        endingPunctuation: .removeFinalDot
    )

    /// Rules for the Messaging style: capitalize sentences, remove final period.
    /// Matches how people write chats/DMs — proper sentence starts without the
    /// chilly "final dot" that reads as passive-aggressive in messaging apps.
    public static let messaging = StaticStyleRules(
        capitalizeSentences: true,
        endingPunctuation: .removeFinalDot
    )

    /// Rules for the Formal style: capitalize sentences, add period if absent.
    public static let formal = StaticStyleRules(
        capitalizeSentences: true,
        endingPunctuation: .addIfAbsent
    )
}
