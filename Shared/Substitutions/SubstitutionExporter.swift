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

    static func drain(_ database: SubstitutionDatabase, to archive: SubstitutionFileArchive) {
        let pending = database.pendingExports()
        guard !pending.isEmpty else { return }

        let encoder = SubstitutionJSONCoders.makeEncoder()
        for export in pending {
            switch export {
            case .entry(let substitution):
                archive.writeSnapshot(substitution, encoder: encoder)
            case .tombstone(let id, let deletedAt):
                archive.writeTombstone(id: id, deletedAt: deletedAt, encoder: encoder)
            }
            database.markExported(export)
        }
        Logger.substitutions.info("Substitution export: \(pending.count) record files written")
    }
}
