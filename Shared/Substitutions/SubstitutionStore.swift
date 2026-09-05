import Foundation
import Observation

/// Persistence boundary for the Substitutions list. Views and the
/// text-processing pipeline observe the concrete conforming type's
/// `@Observable` state through this existential.
///
/// The whole list is small enough to keep fully resident in memory, so — unlike
/// `HistoryStore` — there is no pagination. Per-entry storage (one file per
/// Substitution) still applies under the hood so concurrent edits to *different*
/// entries both survive a sync; only a same-entry concurrent edit hits LWW.
@MainActor
protocol SubstitutionStore: AnyObject, Observable {
    /// Live Substitutions, sorted newest-edited first.
    var substitutions: [Substitution] { get }

    /// Creates or updates the Substitution with the given `id`, stamping
    /// `lastUpdated` so the edit wins any cross-device last-writer comparison.
    func upsert(_ substitution: Substitution)

    /// Writes a tombstone and removes the Substitution from memory. The
    /// snapshot file is left on disk so an unsynced peer still merges correctly.
    func delete(_ substitution: Substitution)

    /// Re-reads the Local Store into `substitutions`.
    func reload()
}
