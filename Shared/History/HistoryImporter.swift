import Foundation
import OSLog

/// Reads the record files into the Local Store, once ever.
///
/// This is how history that predates the database becomes readable from it.
/// Nothing is written back and nothing is deleted: every record file stays
/// exactly where it is, which is what makes the old path a rollback path.
///
/// Nonisolated and blocking: reading thousands of files in an iCloud container
/// asks the iCloud daemon about each one, so callers must keep this off the
/// cooperative pool (`withBlockingTask`) and off the launch read path.
nonisolated enum HistoryImporter {

    /// How many files are decoded before a batch is handed to the database.
    /// Batching keeps the import from holding the connection for its whole
    /// run, so a page read from the list still gets between two batches.
    private static let batchSize = 200

    static func importOnce(
        from archive: ConversationFileArchive,
        into database: ConversationDatabase
    ) {
        guard !database.hasImportedRecordFiles else { return }

        let decoder = HistoryJSONCoders.makeDecoder()
        let entries = archive.liveEntries()
        var imported = 0
        var unreadable = 0

        for batch in stride(from: 0, to: entries.count, by: batchSize) {
            let upper = min(batch + batchSize, entries.count)
            var records: [ConversationDatabase.Stored] = []
            for entry in entries[batch..<upper] {
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
            database.saveImported(records)
            imported += records.count
        }

        database.markRecordFilesImported()
        Logger.history.info(
            "History import: \(imported) records from \(archive.directory.lastPathComponent), \(unreadable) unreadable"
        )
    }
}
