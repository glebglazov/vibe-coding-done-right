import SwiftUI

/// The words and the marks the Dictionary editors show. Both apps read them
/// from here, so the feature that is called one thing on macOS is never called
/// another on iOS, and a Trigger Phrase Clash is marked the same way on both.
enum SubstitutionCopy {

    /// The blurb over the list, explaining what an entry does — including
    /// that it leaves the device with every AI request.
    static let overview = "Your Dictionary holds the names, words and values you say. Every entry helps the transcription model and AI modes spell it right, and is sent to your AI provider with each AI request. Its Note is sent too, but only in Dictation. An entry with Triggers also swaps them for its Spelling, exactly, before any other processing. The Dictionary syncs across your devices."

    static let notePlaceholder = "my sister, container tool, my own name"

    static let noteCaption = "Helps Dictation pick this spelling when a word was misheard. Other AI modes use only the spelling, so a Note never ends up in text they write. Sent to your AI provider."

    /// When an entry needs Triggers, and how they match. It names each model
    /// that ignores Spelling Hints, because there a Trigger is the only fix a
    /// mode without AI has.
    static var triggersCaption: String {
        let rules = "Triggers are optional. Add one only when the transcript keeps writing this word wrong. Type the wrong text that it writes. The app then replaces that text with the Spelling, exactly, before any other processing. Matching is case-insensitive and whole-word. When two Triggers overlap, the longest one wins."
        let hintless = TranscriptionModelFamily.allCases.filter { !$0.takesSpellingHints }
        guard !hintless.isEmpty else { return rules }
        let names = ListFormatter.localizedString(byJoining: hintless.map(\.displayName))
        let verb = hintless.count == 1 ? "does" : "do"
        return rules + " \(names) \(verb) not use the Spelling. With \(names), a mode that does not use AI changes this word only through a Trigger."
    }

    /// What an entry is called while its Replacement is still empty.
    static let untitled = "New Entry"

    /// Said on the Trigger that lost a clash, naming the Replacement that fires
    /// instead — the user typed the phrase here, so this is where the answer
    /// belongs.
    static func clashExplanation(_ clash: TriggerPhraseClash) -> String {
        "Another entry also uses this Trigger, and wins it: your dictation gets \"\(clash.winningReplacement)\"."
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
///     "power zha", "powerja"  →  Powierża
///
/// The Trigger Phrases lead because that is the order, not because they name the
/// entry: the Replacement keeps the prominence, being what the entry *is* and
/// what a list of thirty is scanned for. The arrow says the relation out loud,
/// and goes with the Trigger Phrases so a Substitution with no phrases yet shows
/// no dangling one.
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
