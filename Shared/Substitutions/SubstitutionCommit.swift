import Foundation

/// What committing an edited Substitution did — the rules both editors obey, so
/// neither app can word them differently.
///
/// A commit either saves a tidied entry or throws it away: an entry with no
/// Replacement left after trimming is half-typed, and a half-typed Substitution
/// never reaches disk and never syncs to another device.
enum SubstitutionCommit: Equatable {
    /// Persisted, in the form that was actually saved — trimmed, with blank and
    /// duplicate Trigger Phrases dropped. `clashes` are the phrases this entry
    /// claims that another Substitution wins; they are saved too, never refused.
    case saved(Substitution, clashes: [TriggerPhraseClash])
    /// Not persisted: the Replacement was blank after trimming, so an entry
    /// already on disk was deleted and one that never got there stays off it.
    case discarded
}

extension Substitution {

    /// The form a commit saves: whitespace trimmed off the Replacement and every
    /// Trigger Phrase, blank phrases dropped, and phrases claimed twice collapsed
    /// to one. Trimming matters because a phrase with a trailing space can never
    /// match a whole-word boundary, so it would silently never fire.
    func tidiedForCommit() -> Substitution {
        var tidied = self
        tidied.replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        tidied.phrases = phrases.tidiedForCommit()
        return tidied
    }
}

private extension Array where Element == TriggerPhrase {

    /// Trimmed, blanks dropped, and case-insensitive repeats collapsed keeping the
    /// first spelling typed. A repeat produces identical matches with the same
    /// Replacement, so refusing it would be noise. A dropped phrase leaves no
    /// removal behind, because neither a blank nor a repeat of a phrase that
    /// stays live is a Trigger any device is showing.
    func tidiedForCommit() -> [TriggerPhrase] {
        var claimed: Set<String> = []
        return compactMap { phrase in
            let trimmed = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            var tidied = phrase
            tidied.text = trimmed
            guard tidied.isLive else { return tidied }
            guard claimed.insert(trimmed.lowercased()).inserted else { return nil }
            return tidied
        }
    }
}
