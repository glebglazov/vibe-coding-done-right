import Foundation
import OSLog

/// Reads the Substitution record files into the Local Store — this device's own
/// entries the first time, and every change another device makes after that.
///
/// Nothing is written back and nothing is deleted: every record file stays
/// exactly where it is, which is what makes the old path a rollback path. The
/// merge is last-writer-wins and so idempotent, so a pass over a directory
/// nothing has touched costs a read and changes nothing.
///
/// Nonisolated and blocking: reading files in an iCloud container asks the
/// iCloud daemon about each one, so callers must keep this off the cooperative
/// pool (`withBlockingTask`) and off any read path.
nonisolated enum SubstitutionImporter {

    static func merge(
        from archive: SubstitutionFileArchive,
        into database: SubstitutionDatabase
    ) {
        let scan = archive.scan()
        database.merge(scan.substitutions)
        database.applyTombstones(scan.tombstones)
        Logger.substitutions.info(
            "Substitution merge: \(scan.substitutions.count) entries and \(scan.tombstones.count) deletes"
        )
    }
}
