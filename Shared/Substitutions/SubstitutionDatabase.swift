import Foundation
import OSLog

/// Every Substitution this device knows about, plus the deletes it has made,
/// in the Local Store alongside the conversations. Matching a transcript and
/// opening the Substitutions screen both read from here, so neither can block
/// on a remote service (see `docs/adr/0010`).
///
/// A Substitution is stored as its own JSON encoding, so the `extras` bag that
/// preserves keys written by a newer schema round-trips through the database
/// exactly as it round-trips through a record file.
///
/// A query that fails is logged and answered as "nothing" rather than thrown:
/// the list is not worth failing a launch or a dictation over, and the record
/// files remain the durable copy. Only opening the database throws.
nonisolated final class SubstitutionDatabase: Sendable {

    /// Something whose file copy is missing or stale. The exporter writes these
    /// out and marks them exported; until then the database remembers them
    /// across launches, so an edit made while iCloud was unavailable still
    /// reaches the container later.
    enum PendingExport: Sendable {
        case entry(Substitution)
        case tombstone(id: UUID, deletedAt: Date)
    }

    // MARK: - Init

    private let database: SQLiteDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) throws {
        self.database = try SQLiteDatabase(fileURL: fileURL)
        self.encoder = SubstitutionJSONCoders.makeEncoder()
        self.decoder = SubstitutionJSONCoders.makeDecoder()
        try database.execute(Self.schema)
    }

    private static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS substitutions (
            id TEXT PRIMARY KEY NOT NULL,
            last_updated REAL NOT NULL,
            payload BLOB NOT NULL,
            exported INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS substitution_tombstones (
            id TEXT PRIMARY KEY NOT NULL,
            deleted_at REAL NOT NULL,
            exported INTEGER NOT NULL
        );
        """

    // MARK: - Reading

    /// Every live Substitution, newest-edited first — the whole list, because
    /// the list is small enough to stay resident and the matcher needs all of
    /// it on every transcript.
    func all() -> [Substitution] {
        let payloads = read(
            "SELECT payload FROM substitutions ORDER BY last_updated DESC, id ASC"
        ) { $0.blob(0) }
        return payloads.compactMap { payload in
            payload.flatMap { try? decoder.decode(Substitution.self, from: $0) }
        }
    }

    // MARK: - Writing

    /// Stores a Substitution the user just created or edited, leaving its file
    /// copy to the exporter.
    func save(_ substitution: Substitution) {
        guard let payload = try? encoder.encode(substitution) else {
            Logger.substitutions.error("SubstitutionDatabase could not encode \(substitution.id)")
            return
        }
        write(
            """
            INSERT INTO substitutions (id, last_updated, payload, exported)
            VALUES (?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET
                last_updated = excluded.last_updated,
                payload = excluded.payload,
                exported = 0
            """,
            [
                .text(substitution.id.uuidString),
                .double(substitution.lastUpdated.timeIntervalSinceReferenceDate),
                .blob(payload),
            ]
        )
    }

    /// Takes in the Substitutions read out of the record files — this device's
    /// own entries the first time, another device's edits every time after.
    ///
    /// Last-writer-wins on `lastUpdated`, so an entry the user has since edited
    /// here is never clobbered by the older copy a peer still holds, and a pass
    /// over a directory that has not moved changes nothing. Merged entries are
    /// exported by definition: the file they arrived in is the file they owe.
    /// An entry this device has deleted stays deleted — unless the arriving
    /// edit is at or after the delete, which is the resurrection the files
    /// agree on too.
    func merge(_ substitutions: [Substitution]) {
        guard !substitutions.isEmpty else { return }
        do {
            try database.transaction {
                for substitution in substitutions {
                    let payload = try encoder.encode(substitution)
                    let id = substitution.id.uuidString
                    let lastUpdated = substitution.lastUpdated.timeIntervalSinceReferenceDate
                    try database.run(Self.mergeEntry, [
                        .text(id),
                        .double(lastUpdated),
                        .blob(payload),
                        .text(id),
                        .double(lastUpdated),
                    ])
                }
            }
        } catch {
            Logger.substitutions.error("SubstitutionDatabase merge batch failed: \(error)")
        }
    }

    private static let mergeEntry = """
        INSERT INTO substitutions (id, last_updated, payload, exported)
        SELECT ?, ?, ?, 1
        WHERE NOT EXISTS (
            SELECT 1 FROM substitution_tombstones WHERE id = ? AND deleted_at > ?
        )
        ON CONFLICT(id) DO UPDATE SET
            last_updated = excluded.last_updated,
            payload = excluded.payload,
            exported = 1
        WHERE excluded.last_updated > substitutions.last_updated
        """

    /// Takes in the deletes the record files record. A delete wins only when it
    /// is strictly newer than the edit it deletes; an edit at or after the
    /// tombstone resurrects the entry, and the same rule decides it in the
    /// files.
    func applyTombstones(_ tombstones: [SubstitutionFileArchive.Tombstone]) {
        guard !tombstones.isEmpty else { return }
        do {
            try database.transaction {
                for tombstone in tombstones {
                    let id = tombstone.id.uuidString
                    let deletedAt = tombstone.deletedAt.timeIntervalSinceReferenceDate
                    try database.run(
                        "DELETE FROM substitutions WHERE id = ? AND last_updated < ?",
                        [.text(id), .double(deletedAt)]
                    )
                    try database.run(Self.mergeTombstone, [.text(id), .double(deletedAt)])
                }
            }
        } catch {
            Logger.substitutions.error("SubstitutionDatabase tombstone merge failed: \(error)")
        }
    }

    /// A tombstone that already has a file needs no second one, so it lands
    /// exported — but a delete this device made more recently keeps its place
    /// in the export queue.
    private static let mergeTombstone = """
        INSERT INTO substitution_tombstones (id, deleted_at, exported)
        VALUES (?, ?, 1)
        ON CONFLICT(id) DO UPDATE SET
            deleted_at = excluded.deleted_at,
            exported = 1
        WHERE excluded.deleted_at > substitution_tombstones.deleted_at
        """

    func delete(id: UUID, deletedAt: Date) {
        do {
            try database.transaction {
                try database.run(
                    "DELETE FROM substitutions WHERE id = ?",
                    [.text(id.uuidString)]
                )
                try database.run(
                    """
                    INSERT INTO substitution_tombstones (id, deleted_at, exported)
                    VALUES (?, ?, 0)
                    ON CONFLICT(id) DO UPDATE SET
                        deleted_at = excluded.deleted_at,
                        exported = 0
                    """,
                    [.text(id.uuidString), .double(deletedAt.timeIntervalSinceReferenceDate)]
                )
            }
        } catch {
            Logger.substitutions.error("SubstitutionDatabase delete failed: \(error)")
        }
    }

    // MARK: - Export bookkeeping

    func pendingExports() -> [PendingExport] {
        let entries = read(
            "SELECT payload FROM substitutions WHERE exported = 0"
        ) { row -> PendingExport? in
            guard let payload = row.blob(0),
                  let substitution = try? decoder.decode(Substitution.self, from: payload)
            else { return nil }
            return .entry(substitution)
        }
        let tombstones = read(
            "SELECT id, deleted_at FROM substitution_tombstones WHERE exported = 0"
        ) { row -> PendingExport? in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
            return .tombstone(
                id: id,
                deletedAt: Date(timeIntervalSinceReferenceDate: row.double(1))
            )
        }
        return (entries + tombstones).compactMap { $0 }
    }

    func markExported(_ export: PendingExport) {
        switch export {
        case .entry(let substitution):
            write(
                "UPDATE substitutions SET exported = 1 WHERE id = ?",
                [.text(substitution.id.uuidString)]
            )
        case .tombstone(let id, _):
            write(
                "UPDATE substitution_tombstones SET exported = 1 WHERE id = ?",
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
            Logger.substitutions.error("SubstitutionDatabase query failed: \(error)")
            return []
        }
    }

    private func write(_ sql: String, _ values: [SQLiteDatabase.Value]) {
        do {
            try database.run(sql, values)
        } catch {
            Logger.substitutions.error("SubstitutionDatabase write failed: \(error)")
        }
    }
}
