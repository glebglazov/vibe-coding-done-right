import SwiftUI

/// The words and the marks the Substitutions editors show. Both apps read them
/// from here, so the feature that is called one thing on macOS is never called
/// another on iOS, and a Trigger Phrase Clash is marked the same way on both.
enum SubstitutionCopy {

    /// The blurb over the list, explaining what a Substitution does.
    static let overview = "Substitutions swap a spoken Trigger for fixed Replacement text in your dictation, before any other processing. They apply in every mode and sync across your devices."

    /// How a Trigger is matched against what was said, and what happens when
    /// two Substitutions want the same words.
    static let matchingRules = "Matching is case-insensitive and whole-word. A Substitution fires on any of its Triggers, and the longest Trigger wins when two overlap."

    /// What a Substitution is called while its Replacement is still empty.
    static let untitled = "New Substitution"

    /// Said on the Trigger that lost a clash, naming the Replacement that fires
    /// instead — the user typed the phrase here, so this is where the answer
    /// belongs.
    static func clashExplanation(_ clash: TriggerPhraseClash) -> String {
        "Another Substitution also uses this Trigger, and wins it: your dictation gets \"\(clash.winningReplacement)\"."
    }

    /// The name a Substitution is known by — the row's prominent half, and the
    /// detail screen's title.
    static func title(for substitution: Substitution) -> String {
        substitution.replacement.isEmpty ? untitled : substitution.replacement
    }
}

/// A Substitution as one list row, read in the order a person thinks about
/// one: what was said, then what it becomes.
///
///     "power zha", "powerja"  →  Powierza
///
/// The Trigger Phrases lead because that is the side the user recognises the
/// entry by while looking for it; the Replacement still carries the prominence,
/// because it is what the entry *is*. The arrow says the relation out loud, and
/// goes with the Replacement so a Substitution with no phrases yet shows no
/// dangling one.
///
/// Both apps show this, so a row cannot read one way on macOS and another on
/// iOS. Trailing accessories — a "Disabled" tag, a chevron — belong to the app
/// and sit after it.
struct SubstitutionRowLabel: View {
    let substitution: Substitution
    let clashes: [TriggerPhraseClash]

    var body: some View {
        HStack(spacing: 6) {
            if let summary = substitution.triggerSummary(losing: clashes) {
                // The phrases are the side that gives way when the row is
                // narrow: the Replacement takes the width it needs first, so
                // truncation eats phrases and never the name.
                summary
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(SubstitutionCopy.title(for: substitution))
                .foregroundStyle(substitution.replacement.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .opacity(substitution.isEnabled ? 1 : 0.5)
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
