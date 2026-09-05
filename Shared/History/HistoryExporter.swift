import Foundation
import OSLog

/// Writes what the Local Store holds back out as record files, so the other
/// devices keep converging exactly as they did before the read path moved.
///
/// The database remembers what still owes a file, so a record dictated while
/// the container was unreachable — or before it was even resolved at launch —
/// is exported by the next drain rather than lost.
///
/// Nonisolated and blocking: a write into the iCloud container goes through the
/// iCloud daemon, so callers keep this off the main actor and off the
/// cooperative pool.
nonisolated enum HistoryExporter {

    /// - Returns: how many records still owe their file. A row whose write the
    ///   directory refused stays pending, so the next drain writes it and the
    ///   pass that ran this one is not a Settled Pass.
    @discardableResult
    static func drain(_ database: ConversationDatabase, to archive: ConversationFileArchive) -> Int {
        let pending = database.pendingExports()
        guard !pending.isEmpty else { return 0 }

        let encoder = HistoryJSONCoders.makeEncoder()
        var stillOwing = 0
        for export in pending {
            let written: Bool
            switch export {
            case .record(let conversation, let filename):
                written = archive.writeSnapshot(conversation, named: filename, encoder: encoder)
            case .tombstone(let id, let deletedAt):
                written = archive.writeTombstone(id: id, deletedAt: deletedAt, encoder: encoder)
            }
            if written {
                database.markExported(export)
            } else {
                stillOwing += 1
            }
        }
        Logger.history.info(
            "History export: \(pending.count - stillOwing) record files written, \(stillOwing) still owed"
        )
        return stillOwing
    }
}
