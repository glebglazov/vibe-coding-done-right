import Foundation

/// Every Dictionary Entry's Replacement as a preferred spelling: what a
/// Transcription Model that declares the Spelling Hints Capability is told,
/// and what every LLM call is told. Unlike a Substitution it never changes the
/// transcript by itself — a model may ignore it (`docs/adr/0025`).
struct SpellingHints: Equatable, Sendable {
    /// Most recently edited first, so a model with too little room for all of
    /// them keeps the ones the user touched last.
    let spellings: [String]

    static let none = SpellingHints(spellings: [])

    init(_ entries: [Substitution]) {
        var seen = Set<String>()
        spellings = entries
            .filter(\.isEnabled)
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .map { $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private init(spellings: [String]) {
        self.spellings = spellings
    }

    var isEmpty: Bool { spellings.isEmpty }

    /// The system prompt with the hints after it, or unchanged when there are
    /// none. Last, so the mode's own instructions cannot read as overriding
    /// the rule that a hint never adds text the user did not speak.
    func appended(to systemPrompt: String) -> String {
        guard !isEmpty else { return systemPrompt }
        let list = spellings.map { "- \($0)" }.joined(separator: "\n")
        let section = """
        <spelling_hints>
        The speaker often says these names, words and values. When the dictation contains something that sounds like one of them, write it with exactly this spelling. Never add one that the speaker did not say.
        \(list)
        </spelling_hints>
        """
        return systemPrompt.isEmpty ? section : systemPrompt + "\n\n" + section
    }
}
