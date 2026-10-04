import Foundation

/// The text Whisper is primed with: the Vocabulary Prompt the user typed, then
/// as many Spelling Hints as fit after it. Both share the one budget the typed
/// prompt is capped at, because a longer prompt feeds Whisper's repeat loops
/// (`docs/adr/0017`, `docs/adr/0025`).
struct WhisperPrompt: Equatable, Sendable {
    let text: String
    /// Spelling Hints that did not fit, so a settings screen can say so.
    let hintsLeftOut: Int

    init(
        typed: String,
        hints: SpellingHints,
        characterBudget: Int = TranscriptionModelSettings.freeTextPromptCharacterLimit
    ) {
        var parts = [typed.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        var length = parts.first?.count ?? 0
        var leftOut = 0
        for spelling in hints.spellings {
            let added = parts.isEmpty ? spelling.count : Self.separator.count + spelling.count
            guard length + added <= characterBudget else {
                leftOut += 1
                continue
            }
            parts.append(spelling)
            length += added
        }
        text = parts.joined(separator: Self.separator)
        hintsLeftOut = leftOut
    }

    private static let separator = ", "
}
