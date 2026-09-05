import SwiftUI

/// The words and the marks the Substitutions editors show. Both apps read them
/// from here, so the feature that is called one thing on macOS is never called
/// another on iOS, and a Trigger Phrase Clash is marked the same way on both.
enum SubstitutionCopy {

    /// The blurb over the list, explaining what a Substitution does.
    static let overview = "Substitutions swap a spoken Trigger for fixed Replacement text in your dictation, before any other processing. They apply in every mode and sync across your devices."

    /// What a Substitution is called while its Replacement is still empty.
    static let untitled = "New Substitution"

    /// Said on the Trigger that lost a clash, naming the Replacement that fires
    /// instead — the user typed the phrase here, so this is where the answer
    /// belongs.
    static func clashExplanation(_ clash: TriggerPhraseClash) -> String {
        "Another Substitution also uses this Trigger, and wins it: your dictation gets \"\(clash.winningReplacement)\"."
    }

    /// The name a list row leads with.
    static func title(for substitution: Substitution) -> String {
        substitution.replacement.isEmpty ? untitled : substitution.replacement
    }
}

extension Substitution {

    /// The Triggers as one truncating line, clashing ones first. Reordering is
    /// free — Triggers have no precedence between them — and it buys the marking
    /// survival: a clash pushed past the truncation is a clash the user never
    /// sees.
    func triggerSummary(losing clashes: [TriggerPhraseClash]) -> Text? {
        let clashing = clashes.map(\.phrase)
        let lost = Set(clashing.map { $0.lowercased() })
        let winning = triggerPhrases.filter { !lost.contains($0.lowercased()) }

        let segments = clashing.map(Text.markedTrigger) + winning.map { Text($0).foregroundStyle(.secondary) }
        guard let first = segments.first else { return nil }
        return segments.dropFirst().reduce(first) { $0 + Text(", ").foregroundStyle(.secondary) + $1 }
    }
}

private extension Text {

    /// Red carries the meaning and the warning glyph repeats it, so the mark
    /// still reads where the colour does not.
    static func markedTrigger(_ phrase: String) -> Text {
        (Text(Image(systemName: "exclamationmark.triangle.fill")) + Text(" \(phrase)"))
            .foregroundStyle(.red)
    }
}
