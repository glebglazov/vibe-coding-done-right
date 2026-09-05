import Foundation

/// The losing side of a Trigger Phrase Clash: a phrase this Substitution claims
/// that a more recently edited Substitution also claims, and wins. Carries the
/// Replacement that fires instead, so the editors can say what beats it where
/// the phrase was typed instead of announcing that something somewhere is wrong.
struct TriggerPhraseClash: Equatable, Sendable {
    /// The phrase as typed on the losing Substitution.
    let phrase: String
    /// The Replacement the transcript actually gets for this phrase.
    let winningReplacement: String
}

/// Every Trigger Phrase Clash in a list of Substitutions, resolved to a winner.
///
/// A clash is never refused, so both claimants stay saved and only the match is
/// decided: the most recently edited Substitution wins, which is the same rule
/// `SubstitutionMatcher` applies when the two phrases compete over one
/// transcript. Resolution reads `lastUpdated`, never list order, so a list
/// sorted any other way resolves identically.
struct TriggerPhraseClashes: Equatable, Sendable {

    /// Clashes lost, keyed by the losing Substitution. An entry that wins every
    /// phrase it claims is absent.
    private let lost: [UUID: [TriggerPhraseClash]]

    init(among substitutions: [Substitution]) {
        var winners: [String: Substitution] = [:]
        var lost: [UUID: [TriggerPhraseClash]] = [:]

        for entry in substitutions.rankedByMostRecentlyEdited() {
            for phrase in entry.triggerPhrases {
                // Lowercased because phrases are matched case-insensitively:
                // "Power Zha" and "power zha" are the same claim.
                let claim = phrase.lowercased()
                guard let winner = winners[claim], winner.id != entry.id else {
                    winners[claim] = entry
                    continue
                }
                lost[entry.id, default: []].append(
                    TriggerPhraseClash(phrase: phrase, winningReplacement: winner.replacement)
                )
            }
        }

        self.lost = lost
    }

    /// The clashes `substitution` loses — the phrases it claims that another
    /// Substitution's Replacement beats.
    func clashes(for substitution: Substitution) -> [TriggerPhraseClash] {
        lost[substitution.id] ?? []
    }
}

extension Array where Element == Substitution {
    /// Newest edit first, falling back to the order given so two entries stamped
    /// in the same instant still resolve the same way on every device.
    func rankedByMostRecentlyEdited() -> [Substitution] {
        enumerated()
            .sorted { lhs, rhs in
                lhs.element.lastUpdated == rhs.element.lastUpdated
                    ? lhs.offset < rhs.offset
                    : lhs.element.lastUpdated > rhs.element.lastUpdated
            }
            .map(\.element)
    }
}
