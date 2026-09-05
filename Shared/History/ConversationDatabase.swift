import Foundation
import OSLog

/// The Local Store: every conversation this device knows about, plus the
/// deletes it has made, in one SQLite file outside the iCloud container. Every
/// read on the launch, list and paging paths answers from here, so none of them
/// can block on a remote service (see `docs/adr/0010`).
///
/// A conversation is stored as its own JSON encoding, so the `extras` bag that
/// preserves keys written by a newer schema round-trips through the database
/// exactly as it round-trips through a record file.
///
/// A query that fails is logged and answered as "nothing" rather than thrown:
/// the history list is not worth failing a launch or a dictation over, and the
/// record files remain the durable copy. Only opening the database throws.
nonisolated final class ConversationDatabase: Sendable {

    // MARK: - Stored shapes

    /// A conversation as the database holds it: the record, plus the name of
    /// the file it occupies in the synced record directory. Updates rewrite
    /// that same file rather than adding a second one for the same record.
    struct Stored: Sendable {
        let conversation: Conversation
        let filename: String
    }

    /// Something whose file copy is missing or stale. The exporter writes these
    /// out and marks them exported; until then the database remembers them
    /// across launches, so a record written while iCloud was unavailable still
    /// reaches the container later.
    enum PendingExport: Sendable {
        case record(Conversation, filename: String)
        case tombstone(id: UUID, deletedAt: Date)
    }

    // MARK: - Init

    private let database: SQLiteDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) throws {
        self.database = try SQLiteDatabase(fileURL: fileURL)
        self.encoder = HistoryJSONCoders.makeEncoder()
        self.decoder = HistoryJSONCoders.makeDecoder()
        try database.execute(Self.schema)
    }

    private static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY NOT NULL,
            last_updated REAL NOT NULL,
            payload BLOB NOT NULL,
            record_filename TEXT NOT NULL,
            exported INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS conversations_by_recency
            ON conversations (last_updated DESC);
        CREATE TABLE IF NOT EXISTS conversation_tombstones (
            id TEXT PRIMARY KEY NOT NULL,
            deleted_at REAL NOT NULL,
            exported INTEGER NOT NULL
        );
        """

    // MARK: - Reading

    /// Conversations newest first, as the history list shows them.
    func page(offset: Int, limit: Int) -> [Conversation] {
        let payloads = read(
            "SELECT payload FROM conversations ORDER BY last_updated DESC, id ASC LIMIT ? OFFSET ?",
            [.int(Int64(limit)), .int(Int64(offset))]
        ) { $0.blob(0) }
        return payloads.compactMap { payload in
            payload.flatMap { try? decoder.decode(Conversation.self, from: $0) }
        }
    }

    func conversationCount() -> Int {
        read("SELECT COUNT(*) FROM conversations") { Int($0.int(0)) }.first ?? 0
    }

    func stored(id: UUID) -> Stored? {
        read(
            "SELECT payload, record_filename FROM conversations WHERE id = ?",
            [.text(id.uuidString)]
        ) { row -> Stored? in
            guard let payload = row.blob(0),
                  let filename = row.text(1),
                  let conversation = try? decoder.decode(Conversation.self, from: payload)
            else { return nil }
            return Stored(conversation: conversation, filename: filename)
        }.first ?? nil
    }

    // MARK: - Writing

    /// Stores a conversation the device just created or edited, leaving its
    /// file copy to the exporter.
    func save(_ conversation: Conversation, filename: String) {
        guard let payload = try? encoder.encode(conversation) else {
            Logger.history.error("ConversationDatabase could not encode \(conversation.id)")
            return
        }
        write(
            """
            INSERT INTO conversations (id, last_updated, payload, record_filename, exported)
            VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET
                last_updated = excluded.last_updated,
                payload = excluded.payload,
                exported = 0
            """,
            [
                .text(conversation.id.uuidString),
                .double(conversation.lastUpdated.timeIntervalSinceReferenceDate),
                .blob(payload),
                .text(filename),
            ]
        )
    }

    /// Takes in conversations read out of the record files — this device's own
    /// history the first time, another device's edits every time after.
    ///
    /// Last-writer-wins on `lastUpdated`, so a record the user has since
    /// edited here is never clobbered by the older copy a peer still holds,
    /// and a pass over a directory that has not moved changes nothing. Merged
    /// records are exported by definition: the file they arrived in is the
    /// file they owe. A record this device has deleted stays deleted — its
    /// tombstone outranks any snapshot written before it.
    func merge(_ records: [Stored]) {
        do {
            try database.transaction {
                for record in records {
                    let payload = try encoder.encode(record.conversation)
                    let id = record.conversation.id.uuidString
                    let lastUpdated = record.conversation.lastUpdated.timeIntervalSinceReferenceDate
                    try database.run(Self.mergeRecord, [
                        .text(id),
                        .double(lastUpdated),
                        .blob(payload),
                        .text(record.filename),
                        .text(id),
                        .double(lastUpdated),
                    ])
                }
            }
        } catch {
            Logger.history.error("ConversationDatabase merge batch failed: \(error)")
        }
    }

    private static let mergeRecord = """
        INSERT INTO conversations (id, last_updated, payload, record_filename, exported)
        SELECT ?, ?, ?, ?, 1
        WHERE NOT EXISTS (
            SELECT 1 FROM conversation_tombstones WHERE id = ? AND deleted_at >= ?
        )
        ON CONFLICT(id) DO UPDATE SET
            last_updated = excluded.last_updated,
            payload = excluded.payload,
            record_filename = excluded.record_filename,
            exported = 1
        WHERE excluded.last_updated > conversations.last_updated
        """

    /// Takes in the deletes the record files record. A delete removes the
    /// conversation unless it has been edited since — an edit newer than the
    /// tombstone is a resurrection, and the same rule decides it in the files.
    func applyTombstones(_ tombstones: [ConversationFileArchive.Tombstone]) {
        guard !tombstones.isEmpty else { return }
        do {
            try database.transaction {
                for tombstone in tombstones {
                    let id = tombstone.id.uuidString
                    let deletedAt = tombstone.deletedAt.timeIntervalSinceReferenceDate
                    try database.run(
                        "DELETE FROM conversations WHERE id = ? AND last_updated <= ?",
                        [.text(id), .double(deletedAt)]
                    )
                    try database.run(Self.mergeTombstone, [.text(id), .double(deletedAt)])
                }
            }
        } catch {
            Logger.history.error("ConversationDatabase tombstone merge failed: \(error)")
        }
    }

    /// A tombstone that already has a file needs no second one, so it lands
    /// exported — but a delete this device made more recently keeps its place
    /// in the export queue.
    private static let mergeTombstone = """
        INSERT INTO conversation_tombstones (id, deleted_at, exported)
        VALUES (?, ?, 1)
        ON CONFLICT(id) DO UPDATE SET
            deleted_at = excluded.deleted_at,
            exported = 1
        WHERE excluded.deleted_at > conversation_tombstones.deleted_at
        """

    func delete(id: UUID, deletedAt: Date) {
        do {
            try database.transaction {
                try database.run(
                    "DELETE FROM conversations WHERE id = ?",
                    [.text(id.uuidString)]
                )
                try database.run(Self.insertTombstone, [
                    .text(id.uuidString),
                    .double(deletedAt.timeIntervalSinceReferenceDate),
                ])
            }
        } catch {
            Logger.history.error("ConversationDatabase delete failed: \(error)")
        }
    }

    /// Tombstones every stored conversation, including the ones no page has
    /// loaded, and empties the table.
    func deleteAll(deletedAt: Date) {
        do {
            try database.transaction {
                try database.run(
                    """
                    INSERT INTO conversation_tombstones (id, deleted_at, exported)
                    SELECT id, ?, 0 FROM conversations
                    ON CONFLICT(id) DO UPDATE SET
                        deleted_at = excluded.deleted_at,
                        exported = 0
                    """,
                    [.double(deletedAt.timeIntervalSinceReferenceDate)]
                )
                try database.run("DELETE FROM conversations")
            }
        } catch {
            Logger.history.error("ConversationDatabase clear failed: \(error)")
        }
    }

    private static let insertTombstone = """
        INSERT INTO conversation_tombstones (id, deleted_at, exported)
        VALUES (?, ?, 0)
        ON CONFLICT(id) DO UPDATE SET
            deleted_at = excluded.deleted_at,
            exported = 0
        """

    // MARK: - Export bookkeeping

    func pendingExports() -> [PendingExport] {
        let records = read(
            "SELECT payload, record_filename FROM conversations WHERE exported = 0",
            []
        ) { row -> PendingExport? in
            guard let payload = row.blob(0),
                  let filename = row.text(1),
                  let conversation = try? decoder.decode(Conversation.self, from: payload)
            else { return nil }
            return .record(conversation, filename: filename)
        }
        let tombstones = read(
            "SELECT id, deleted_at FROM conversation_tombstones WHERE exported = 0",
            []
        ) { row -> PendingExport? in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
            return .tombstone(
                id: id,
                deletedAt: Date(timeIntervalSinceReferenceDate: row.double(1))
            )
        }
        return (records + tombstones).compactMap { $0 }
    }

    func markExported(_ export: PendingExport) {
        switch export {
        case .record(let conversation, _):
            write(
                "UPDATE conversations SET exported = 1 WHERE id = ?",
                [.text(conversation.id.uuidString)]
            )
        case .tombstone(let id, _):
            write(
                "UPDATE conversation_tombstones SET exported = 1 WHERE id = ?",
                [.text(id.uuidString)]
            )
        }
    }

    // MARK: - Statement plumbing

    private func read<T>(
        _ sql: String,
        _ values: [SQLiteDatabase.Value] = [],
        readingEach read: (SQLiteDatabase.Row) -> T
    ) -> [T] {
        do {
            return try database.query(sql, values, readingEach: read)
        } catch {
            Logger.history.error("ConversationDatabase query failed: \(error)")
            return []
        }
    }

    private func write(_ sql: String, _ values: [SQLiteDatabase.Value]) {
        do {
            try database.run(sql, values)
        } catch {
            Logger.history.error("ConversationDatabase write failed: \(error)")
        }
    }
}
