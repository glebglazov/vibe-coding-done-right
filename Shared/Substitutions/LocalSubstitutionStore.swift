import Foundation
import OSLog

/// The Substitution store every read answers from: the matcher and the
/// Substitutions screen both come out of the on-device `SubstitutionDatabase`,
/// never out of iCloud.
///
/// The record files stay the sync transport. An edit lands in the database
/// first and is exported to its file immediately behind it — immediately, not
/// on the next reconcile pass, because a Substitution the other device has not
/// heard about produces visibly wrong text there. The directory those files
/// live in is handed over *after* the store is readable (see `docs/adr/0010`).
@MainActor
@Observable
final class LocalSubstitutionStore: SubstitutionStore, RecordFileSyncedStore {

    // MARK: - State

    private(set) var substitutions: [Substitution] = []

    /// Internal, not private: the reconciler merges the record files into
    /// these same rows, and the store publishes the result.
    let database: SubstitutionDatabase

    /// The record files this store exports to. Nil until `syncRecordFiles`
    /// hands over the directory; edits made before then are remembered by the
    /// database and exported by the first drain.
    private var recordFiles: SubstitutionFileArchive?

    /// Sendable payload produced off the main actor by `loadSnapshot`. The
    /// `@MainActor` store is installed from it without touching disk.
    struct Snapshot: Sendable {
        let database: SubstitutionDatabase
        let substitutions: [Substitution]
    }

    // MARK: - Init

    /// Constructs from a pre-loaded `Snapshot`. Performs no I/O.
    init(snapshot: Snapshot) {
        self.database = snapshot.database
        self.substitutions = snapshot.substitutions
    }

    /// Opens the Local Store and reads the whole list. Local disk only —
    /// nothing here can block on iCloud — but blocking all the same, so callers
    /// run it off the cooperative pool and pair it with `init(snapshot:)`.
    nonisolated static func loadSnapshot(
        fileURL: URL = LocalStoreFile.url
    ) throws -> Snapshot {
        let database = try openDatabase(at: fileURL)
        return Snapshot(database: database, substitutions: database.all())
    }

    nonisolated private static func openDatabase(at fileURL: URL) throws -> SubstitutionDatabase {
        do {
            return try SubstitutionDatabase(fileURL: fileURL)
        } catch let error as SQLiteError where error.isCorruption {
            // The record files still hold every entry, so discarding a corrupt
            // database costs one merge rather than the Substitutions themselves.
            Logger.substitutions.error("Local store corrupt, rebuilding: \(error)")
            LocalStoreFile.discardCorruptDatabase(at: fileURL)
            return try SubstitutionDatabase(fileURL: fileURL)
        }
    }

    // MARK: - SubstitutionStore

    func upsert(_ substitution: Substitution) {
        var entry = substitution
        entry.lastUpdated = Date()
        database.save(entry)

        substitutions.removeAll { $0.id == entry.id }
        substitutions.insert(entry, at: 0)
        exportPendingEntries()
    }

    func delete(_ substitution: Substitution) {
        let known = substitutions.first { $0.id == substitution.id } ?? substitution
        database.delete(id: known.id, deletedAt: Self.tombstoneStamp(after: known.lastUpdated))
        substitutions.removeAll { $0.id == known.id }
        exportPendingEntries()
    }

    func reload() {
        substitutions = database.all()
    }

    // MARK: - Record files

    /// Brings a directory of record files into the database, writes out
    /// whatever the database still owes it, and republishes the list.
    func syncRecordFiles(in directory: URL) async {
        let database = self.database
        let archive = SubstitutionFileArchive(directory: directory)
        await withBlockingTask(qos: .utility) {
            archive.ensureDirectoryExists()
            SubstitutionImporter.merge(from: archive, into: database)
            SubstitutionExporter.drain(database, to: archive)
        }
        recordFiles = archive
        reload()
    }

    private func exportPendingEntries() {
        guard let recordFiles else { return }
        let database = self.database
        Task.detached(priority: .utility) {
            SubstitutionExporter.drain(database, to: recordFiles)
        }
    }

    // MARK: - Tombstone stamping

    /// One millisecond: what `SubstitutionJSONCoders` keeps of a `Date`.
    private static let storageTimestampResolution: TimeInterval = 0.001

    /// Stamps a tombstone so it dominates the edit it deletes. Stamps
    /// round-trip through the record files at millisecond resolution, so a
    /// delete issued in the same millisecond as the edit before it reads back
    /// as a tie — and a tie leaves the entry live, which would let a cleared
    /// Substitution return on the next merge. Deleting an entry is always
    /// causally after the edit it saw, so the stamp is carried forward one
    /// storage tick when the clock has not moved.
    private static func tombstoneStamp(after lastUpdated: Date, now: Date = Date()) -> Date {
        max(now, lastUpdated + storageTimestampResolution)
    }
}
