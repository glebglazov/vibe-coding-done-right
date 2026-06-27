import Foundation

/// Append-only event marking a `Substitution` as deleted. Persisted as its own
/// file (`<id>.deleted.json`) next to the snapshot so peer devices merge deletes
/// without clobbering each other's edits.
///
/// Delete-vs-edit precedence is decided on `deletedAt`: a tombstone wins (and
/// suppresses the snapshot) only when `deletedAt > Substitution.lastUpdated`.
/// A later edit on another device — snapshot `lastUpdated` ≥ `deletedAt` —
/// correctly resurrects the entry.
struct SubstitutionTombstone: Codable, Equatable, Sendable {
    let substitutionID: UUID
    let deletedAt: Date

    init(substitutionID: UUID, deletedAt: Date) {
        self.substitutionID = substitutionID
        self.deletedAt = deletedAt
    }
}
