import Foundation
import OSLog

/// Collapses the Substitutions that hold one Replacement into the single entry
/// they always were.
///
/// Two devices that were both told about `gleb@example.com` while offline each
/// made their own entry for it, with their own id and their own Trigger Phrase.
/// They are not a Trigger Phrase Clash — a clash is two *different*
/// Replacements competing for one phrase, which the user has to settle — so
/// they are merged instead: the older entry survives, the Trigger Phrases
/// combine, and the younger one is deleted the way any Substitution is
/// (ADR-0011).
///
/// The rule reads only what the entries themselves carry, so both devices reach
/// the same survivor without coordinating. This runs on a sync pass and not on
/// an edit: a Replacement being typed passes through other entries' text on its
/// way to its own, and merging under the caret is not what the user asked for.
nonisolated enum SubstitutionConvergence {

    /// What one pass decided: the entries to rewrite, and the entries whose
    /// Trigger Phrases those now carry, to delete.
    struct Outcome: Equatable, Sendable {
        let survivors: [Substitution]
        let losers: [Substitution]

        var isEmpty: Bool { survivors.isEmpty && losers.isEmpty }
    }

    /// Merges the Substitutions in the Local Store, exporting the survivors and
    /// the deletes through the same pending-export bookkeeping every other
    /// write uses.
    static func converge(in database: SubstitutionDatabase, now: Date = Date()) {
        let outcome = outcome(for: database.all(), now: now)
        guard !outcome.isEmpty else { return }

        for survivor in outcome.survivors {
            database.save(survivor)
        }
        for loser in outcome.losers {
            database.delete(id: loser.id, deletedAt: MergeStamp.deleting(after: loser.lastUpdated, now: now))
        }
        Logger.substitutions.info(
            "Substitution convergence: \(outcome.losers.count) entries merged into \(outcome.survivors.count)"
        )
    }

    /// The merge itself, over a list rather than a database, so the rule can be
    /// read and tested as the rule.
    ///
    /// A group of one is untouched, and so is a survivor whose phrases already
    /// hold everything the losers knew — a pass over a list that has already
    /// converged writes nothing, which is what stops two devices rewriting each
    /// other's files forever.
    static func outcome(for substitutions: [Substitution], now: Date = Date()) -> Outcome {
        var survivors: [Substitution] = []
        var losers: [Substitution] = []

        for group in groupedByReplacement(substitutions) where group.count > 1 {
            let ranked = group.sorted(by: olderFirst)
            var survivor = ranked[0]
            let merged = ranked.dropFirst()

            let phrases = merged.reduce(survivor.phrases) { $0.merged(with: $1.phrases) }
            losers.append(contentsOf: merged)

            guard phrases != survivor.phrases else { continue }
            survivor.phrases = phrases
            survivor.lastUpdated = now
            survivors.append(survivor)
        }

        return Outcome(survivors: survivors, losers: losers)
    }

    /// Entries holding one Replacement, exactly as typed: a Replacement is
    /// injected verbatim, so two that differ by a character are two answers and
    /// not one. An entry with no Replacement yet is nobody's duplicate.
    private static func groupedByReplacement(_ substitutions: [Substitution]) -> [[Substitution]] {
        Dictionary(grouping: substitutions.filter { !$0.replacement.isEmpty }, by: \.replacement)
            .values
            .map { $0 }
    }

    /// The entry made first survives. Two entries made in the same instant are
    /// ranked by id, which is arbitrary but identical on every device — and an
    /// arbitrary answer both devices reach beats a reasoned one they disagree
    /// on, because disagreement here deletes both entries.
    private static func olderFirst(_ lhs: Substitution, _ rhs: Substitution) -> Bool {
        lhs.createdAt == rhs.createdAt
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.createdAt < rhs.createdAt
    }
}
