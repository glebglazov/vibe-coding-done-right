import Foundation
import OSLog

/// Writes what the Local Store holds back out as record files, so the other
/// devices keep converging exactly as they did before the read path moved.
///
/// The database remembers what still owes a file, so an edit made while the
/// container was unreachable — or before it was even resolved at launch — is
/// exported by the next drain rather than lost.
///
/// Nonisolated and blocking: a write into the iCloud container goes through the
/// iCloud daemon, so callers keep this off the main actor and off the
/// cooperative pool.
nonisolated enum SubstitutionExporter {

    /// - Returns: how many entries still owe their file, on the same terms as
    ///   `HistoryExporter.drain`.
    @discardableResult
    static func drain(_ database: SubstitutionDatabase, to archive: SubstitutionFileArchive) -> Int {
        let pending = database.pendingExports()
        guard !pending.isEmpty else { return 0 }

        let encoder = SubstitutionJSONCoders.makeEncoder()
        var stillOwing = 0
        for export in pending {
            let written: Bool
            switch export {
            case .entry(let substitution):
                written = archive.writeSnapshot(substitution, encoder: encoder)
            case .tombstone(let id, let deletedAt):
                written = archive.writeTombstone(id: id, deletedAt: deletedAt, encoder: encoder)
            }
            if written {
                database.markExported(export)
            } else {
                stillOwing += 1
            }
        }
        Logger.substitutions.info(
            "Substitution export: \(pending.count - stillOwing) record files written, \(stillOwing) still owed"
        )
        return stillOwing
    }
}
