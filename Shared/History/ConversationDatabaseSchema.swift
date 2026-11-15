import Foundation
import OSLog

/// Brings the Local Store's conversation tables to the shape this build reads,
/// from an empty file or from any shape an earlier build left behind. Every
/// step is safe to run again, so it runs on every open.
nonisolated enum ConversationDatabaseSchema {

    static func prepare(_ database: SQLiteDatabase) throws {
        try database.execute(tables)
        // Between the two: a database written before capture time existed has
        // the table but not the column, so the index over it cannot be created
        // until the migration has added it.
        try adoptCaptureTimes(in: database)
        try adoptDiscardedFlags(in: database)
        try database.execute(indexes)
    }

    private static let tables = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY NOT NULL,
            captured_at REAL NOT NULL,
            last_updated REAL NOT NULL,
            payload BLOB NOT NULL,
            record_filename TEXT NOT NULL,
            exported INTEGER NOT NULL,
            discarded INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS conversation_tombstones (
            id TEXT PRIMARY KEY NOT NULL,
            deleted_at REAL NOT NULL,
            exported INTEGER NOT NULL
        );
        """

    /// Recency by merge stamp is nobody's ordering any more. The partial index
    /// pages the Discarded filter without a scan of the whole table.
    private static let indexes = """
        DROP INDEX IF EXISTS conversations_by_recency;
        CREATE INDEX IF NOT EXISTS conversations_by_capture
            ON conversations (captured_at DESC);
        CREATE INDEX IF NOT EXISTS discarded_conversations_by_capture
            ON conversations (captured_at DESC) WHERE discarded = 1;
        """

    /// Gives a database written before capture time was stored the column it
    /// now sorts by, filled the same way an import fills it: from the record
    /// filename, which has carried the capture time all along.
    private static func adoptCaptureTimes(in database: SQLiteDatabase) throws {
        guard try !hasColumn("captured_at", in: database) else { return }

        try database.execute(
            "ALTER TABLE conversations ADD COLUMN captured_at REAL NOT NULL DEFAULT 0"
        )
        let rows = try database.query(
            "SELECT id, record_filename, last_updated FROM conversations",
            []
        ) { row -> (String, Date)? in
            guard let id = row.text(0), let filename = row.text(1) else { return nil }
            let capturedAt = ConversationFileArchive.captureTime(fromFilename: filename)
                ?? Date(timeIntervalSinceReferenceDate: row.double(2))
            return (id, capturedAt)
        }
        try database.transaction {
            for (id, capturedAt) in rows.compactMap({ $0 }) {
                try database.run(
                    "UPDATE conversations SET captured_at = ? WHERE id = ?",
                    [.double(capturedAt.timeIntervalSinceReferenceDate), .text(id)]
                )
            }
        }
        Logger.history.info("Local store adopted capture times for \(rows.count) conversations")
    }

    /// Gives a database written before Conversation status existed the column
    /// the Discarded filter pages by, and brings the column back in line with
    /// the payloads. The payloads are the authority: a build without the column
    /// keeps a discarded status in the payload's unknown keys, and it still
    /// shares this database (ADR-0014). Whatever it merged or edited since the
    /// last open has a column that may say the opposite of its payload. One
    /// transaction, so no crash can leave the column added but not filled.
    private static func adoptDiscardedFlags(in database: SQLiteDatabase) throws {
        try database.transaction {
            if try !hasColumn("discarded", in: database) {
                try database.execute(
                    "ALTER TABLE conversations ADD COLUMN discarded INTEGER NOT NULL DEFAULT 0"
                )
            }
            try database.run(reconcileDiscardedFlags)
        }
    }

    /// The payload is JSON text in a blob. The cast keeps SQLite from reading
    /// the blob as JSONB. A payload that is not valid JSON keeps its column as
    /// it is, so one unreadable row cannot fail the whole open. A "discarded"
    /// key that is not an object decodes as a normal entry, so it counts as one.
    private static let reconcileDiscardedFlags = """
        UPDATE conversations
        SET discarded = json_type(CAST(payload AS TEXT), '$.discarded') IS 'object'
        WHERE discarded != CASE
            WHEN json_valid(CAST(payload AS TEXT))
            THEN json_type(CAST(payload AS TEXT), '$.discarded') IS 'object'
            ELSE discarded
        END
        """

    private static func hasColumn(_ name: String, in database: SQLiteDatabase) throws -> Bool {
        let count = try database.query(
            "SELECT COUNT(*) FROM pragma_table_info('conversations') WHERE name = ?",
            [.text(name)]
        ) { $0.int(0) }.first ?? 0
        return count > 0
    }
}
