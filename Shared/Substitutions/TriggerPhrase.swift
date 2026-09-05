import Foundation

/// One of the spoken texts that activates a Substitution, carrying the stamps
/// that say whether it is still on the entry.
///
/// A phrase is not a bare string because Substitution Convergence combines the
/// phrase lists of two entries, and a union of bare strings resurrects a phrase
/// the moment a device that never saw its removal syncs its older copy. The
/// removal travelling on the phrase itself is what makes a delete stick
/// (ADR-0011).
///
/// `id` is identity for *editing*: retyping a phrase moves its `text` and keeps
/// its stamps, so fixing a spelling never records the old one as a removal.
/// Merging keys on the text instead, because two devices that typed the same
/// phrase separately have no id in common.
nonisolated struct TriggerPhrase: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    /// When this phrase was put on the entry.
    var addedAt: Date
    /// When it was taken off, if it has been.
    var removedAt: Date?

    init(id: UUID = UUID(), text: String, addedAt: Date, removedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.addedAt = addedAt
        self.removedAt = removedAt
    }

    /// Whether the phrase is still one of the entry's Triggers.
    ///
    /// A removal beats the addition it is newer than, and only that one: a
    /// phrase added back after a peer removed it stays, the same way an edit at
    /// or after a `SubstitutionTombstone` resurrects the entry it deleted.
    var isLive: Bool {
        guard let removedAt else { return true }
        return addedAt >= removedAt
    }

    /// Takes the phrase off the entry, stamped past its own addition so the
    /// removal cannot read back as a tie once the stamps round-trip through a
    /// Record File.
    mutating func remove(at now: Date = Date()) {
        removedAt = MergeStamp.deleting(after: addedAt, now: now)
    }
}

extension Array where Element == TriggerPhrase {

    /// The phrases of two copies of one Substitution as a single list: each
    /// phrase keeps the latest addition and the latest removal either copy
    /// knows, so a removal beats a stale addition from a device that never saw
    /// it, and nothing returns from an older copy.
    ///
    /// Phrases match on their text, case-insensitively, since two devices that
    /// typed one phrase separately share no id. The receiver's spelling and id
    /// win, which makes the result depend only on which entry survives — so
    /// every device computes the same list.
    func merged(with other: [TriggerPhrase]) -> [TriggerPhrase] {
        var order: [String] = []
        var byText: [String: TriggerPhrase] = [:]

        for phrase in self + other {
            let claim = phrase.text.lowercased()
            guard var known = byText[claim] else {
                byText[claim] = phrase
                order.append(claim)
                continue
            }
            known.addedAt = Swift.max(known.addedAt, phrase.addedAt)
            known.removedAt = [known.removedAt, phrase.removedAt].compactMap { $0 }.max()
            byText[claim] = known
        }

        return order.compactMap { byText[$0] }
    }
}
