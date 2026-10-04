import Foundation

/// Every Dictionary Entry's Replacement as a preferred spelling: what a
/// Transcription Model that declares the Spelling Hints Capability is told,
/// and what every LLM call is told. Unlike a Substitution it never changes the
/// transcript by itself — a model may ignore it (`docs/adr/0025`).
struct SpellingHints: Equatable, Sendable {
    struct Hint: Equatable, Sendable {
        let spelling: String
        let note: String
    }

    /// How much of each hint an LLM prompt carries. Each platform's mode type
    /// picks one as its `hintDetail` (`docs/adr/0026`).
    enum Detail: Sendable {
        case spellingsOnly
        case withNotes
    }

    /// Most recently edited first, so a model with too little room for all of
    /// them keeps the ones the user touched last. Two spellings that differ
    /// only in case contradict each other, so the more recent one is kept.
    let hints: [Hint]

    static let none = SpellingHints(hints: [])

    init(_ entries: [Substitution]) {
        var seen = Set<String>()
        hints = entries
            .filter(\.isEnabled)
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .map {
                Hint(
                    spelling: $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines),
                    note: $0.note.split(whereSeparator: \.isNewline).joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                )
            }
            .filter { !$0.spelling.isEmpty && seen.insert($0.spelling.lowercased()).inserted }
    }

    private init(hints: [Hint]) {
        self.hints = hints
    }

    var spellings: [String] { hints.map(\.spelling) }

    var isEmpty: Bool { hints.isEmpty }

    /// The system prompt with the hints after it, or unchanged when there are
    /// none. Last, so the mode's own instructions cannot read as overriding
    /// the rule that a hint never adds text the user did not speak.
    func appended(to systemPrompt: String, detail: Detail) -> String {
        guard !isEmpty else { return systemPrompt }
        let list = hints.map { hint in
            detail == .withNotes && !hint.note.isEmpty
                ? "- \(hint.spelling) (\(hint.note))"
                : "- \(hint.spelling)"
        }.joined(separator: "\n")
        let section = """
        <spelling_hints>
        The speaker often says these names, words and values. When the dictation contains something that sounds like one of them, write it with exactly this spelling. Never add one that the speaker did not say.
        \(list)
        </spelling_hints>
        """
        return systemPrompt.isEmpty ? section : systemPrompt + "\n\n" + section
    }
}
