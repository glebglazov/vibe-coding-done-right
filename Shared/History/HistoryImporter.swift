import Foundation
import OSLog

/// Reads the record files into the Local Store — this device's own history the
/// first time, and every change another device makes after that.
///
/// Nothing is written back and nothing is deleted: every record file stays
/// exactly where it is, which is what makes the old path a rollback path. The
/// merge is last-writer-wins and so idempotent, so a pass over a directory
/// nothing has touched costs a read and changes nothing.
///
/// Nonisolated and blocking: reading thousands of files in an iCloud container
/// asks the iCloud daemon about each one, so callers must keep this off the
/// cooperative pool (`withBlockingTask`) and off the launch read path.
nonisolated enum HistoryImporter {

    /// How many files are decoded before a batch is handed to the database.
    /// Batching keeps the merge from holding the connection for its whole
    /// run, so a page read from the list still gets between two batches.
    private static let batchSize = 200

    static func merge(
        from archive: ConversationFileArchive,
        into database: ConversationDatabase
    ) {
        let cutoff = HistorySync.replicationWindow.map { Date(timeIntervalSinceNow: -$0) }
        let scan = archive.scan(modifiedAfter: cutoff)
        let decoder = HistoryJSONCoders.makeDecoder()
        var merged = 0
        var unreadable = 0

        for batch in stride(from: 0, to: scan.entries.count, by: batchSize) {
            let upper = min(batch + batchSize, scan.entries.count)
            var records: [ConversationDatabase.Stored] = []
            for entry in scan.entries[batch..<upper] {
                guard let conversation = ConversationFileArchive.readConversation(
                    at: entry.url,
                    decoder: decoder
                ) else {
                    unreadable += 1
                    continue
                }
                records.append(
                    ConversationDatabase.Stored(
                        conversation: conversation,
                        filename: entry.url.lastPathComponent
                    )
                )
            }
            database.merge(records)
            merged += records.count
        }

        database.applyTombstones(scan.tombstones)
        Logger.history.info(
            "History merge: \(merged) records and \(scan.tombstones.count) deletes from \(archive.directory.lastPathComponent), \(unreadable) unreadable"
        )
    }
}
