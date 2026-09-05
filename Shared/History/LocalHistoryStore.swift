import Foundation
import OSLog

/// The history store every read answers from: launch, the list and paging all
/// come out of the on-device `ConversationDatabase`, never out of iCloud.
///
/// The record files stay the sync transport. A write lands in the database
/// first and is exported to a file behind it, so a dictation is recorded at
/// local-disk speed and the other devices converge as they always did. The
/// directory those files live in is resolved *after* the store is readable —
/// resolving the iCloud container takes seconds on a first launch, and no read
/// waits for it (see `docs/adr/0010`).
@MainActor
@Observable
final class LocalHistoryStore: HistoryStore {

    // MARK: - Constants

    /// How far back the list pages before it stops. Older conversations stay
    /// in the database — never deleted — but stay invisible until a future
    /// version exposes a full-history view.
    nonisolated static let maxConversations = 500
    nonisolated static let pageSize = 50

    // MARK: - State

    private(set) var conversations: [Conversation] = []

    var latestConversation: Conversation? { conversations.first }
    var hasMorePages: Bool { conversations.count < min(storedCount, Self.maxConversations) }

    private let database: ConversationDatabase
    /// How many conversations the database holds, loaded or not — what tells
    /// the list whether another page exists.
    private var storedCount: Int
    /// The record files this store exports to. Nil until `linkRecordFiles`
    /// resolves the directory; writes made before then are remembered by the
    /// database and exported by the first drain.
    private var recordFiles: ConversationFileArchive?

    /// Sendable payload produced off the main actor by `loadSnapshot`. The
    /// `@MainActor` store is installed from it without touching disk.
    struct Snapshot: Sendable {
        let database: ConversationDatabase
        let conversations: [Conversation]
        let storedCount: Int
    }

    // MARK: - Init

    /// Constructs from a pre-loaded `Snapshot`. Performs no I/O.
    init(snapshot: Snapshot) {
        self.database = snapshot.database
        self.conversations = snapshot.conversations
        self.storedCount = snapshot.storedCount
    }

    /// Opens the database and reads the first page. Local disk only — nothing
    /// here can block on iCloud — but blocking all the same, so callers run it
    /// off the cooperative pool and pair it with `init(snapshot:)`.
    /// Where the database lives — never in the iCloud container. SQLite with a
    /// WAL is several files mutating constantly, and iCloud file coordination
    /// resolves a conflict between them as a corrupted database rather than a
    /// merge. `FileHistoryStore.localStorageRoot` is the app's own storage: the
    /// app group on iOS, Application Support on macOS.
    nonisolated static var defaultDatabaseURL: URL {
        FileHistoryStore.localStorageRoot.appendingPathComponent("history.sqlite3")
    }

    nonisolated static func loadSnapshot(
        fileURL: URL = LocalHistoryStore.defaultDatabaseURL
    ) throws -> Snapshot {
        let database = try openDatabase(at: fileURL)
        return Snapshot(
            database: database,
            conversations: database.page(offset: 0, limit: pageSize),
            storedCount: database.conversationCount()
        )
    }

    nonisolated private static func openDatabase(at fileURL: URL) throws -> ConversationDatabase {
        do {
            return try ConversationDatabase(fileURL: fileURL)
        } catch {
            // A database SQLite refuses to open is a corrupt one. The record
            // files still hold every record, so discarding it costs one
            // re-import rather than the history itself.
            Logger.history.error("Local history database unusable, rebuilding: \(error)")
            let fileManager = FileManager.default
            for sibling in ["", "-wal", "-shm"] {
                try? fileManager.removeItem(at: URL(fileURLWithPath: fileURL.path + sibling))
            }
            return try ConversationDatabase(fileURL: fileURL)
        }
    }

    // MARK: - HistoryStore

    func record(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        label: String?
    ) {
        let now = Date()
        let stored = database.stored(id: conversationID)
        let conversation: Conversation
        if var prior = stored?.conversation {
            prior.inputSegments = inputSegments
            prior.output = output
            prior.label = label
            prior.lastUpdated = now
            conversation = prior
        } else {
            conversation = Conversation(
                id: conversationID,
                inputSegments: inputSegments,
                output: output,
                label: label,
                lastUpdated: now
            )
        }
        // An edit rewrites the file the record already occupies, so the
        // container never grows a second file for one conversation.
        let filename = stored?.filename
            ?? ConversationFileArchive.snapshotFilename(id: conversationID, createdAt: now)
        database.save(conversation, filename: filename)

        if stored == nil { storedCount += 1 }
        conversations.removeAll { $0.id == conversationID }
        conversations.insert(conversation, at: 0)
        exportPendingRecords()
    }

    func removeConversation(_ conversation: Conversation) {
        database.delete(id: conversation.id, deletedAt: Date())
        conversations.removeAll { $0.id == conversation.id }
        storedCount = max(0, storedCount - 1)
        exportPendingRecords()
    }

    func clearAll() {
        database.deleteAll(deletedAt: Date())
        conversations.removeAll()
        storedCount = 0
        exportPendingRecords()
    }

    func loadNextPage() {
        guard hasMorePages else { return }
        let limit = min(Self.pageSize, Self.maxConversations - conversations.count)
        let loaded = database.page(offset: conversations.count, limit: limit)
        // A record written since the last page shifted the window by one, so
        // the page can repeat a conversation the list already shows.
        let known = Set(conversations.map(\.id))
        conversations.append(contentsOf: loaded.filter { !known.contains($0.id) })
    }

    // MARK: - Record files

    /// Links the directory of record files this device syncs through: imports
    /// it into the database the first time, then exports anything the files
    /// are missing. Called after the store is readable, never before — it
    /// resolves the iCloud container, which blocks.
    func linkRecordFiles(syncEnabled: Bool) async {
        let directory = await withBlockingTask(qos: .utility) {
            HistorySync.prepareRecordFilesDirectory(syncEnabled: syncEnabled)
        }
        await linkRecordFiles(in: directory)
    }

    func linkRecordFiles(in directory: URL) async {
        let database = self.database
        let archive = ConversationFileArchive(directory: directory)
        await withBlockingTask(qos: .utility) {
            archive.ensureDirectoryExists()
            HistoryImporter.importOnce(from: archive, into: database)
            HistoryExporter.drain(database, to: archive)
        }
        recordFiles = archive
        reloadFirstPage()
    }

    private func exportPendingRecords() {
        guard let recordFiles else { return }
        let database = self.database
        Task.detached(priority: .utility) {
            HistoryExporter.drain(database, to: recordFiles)
        }
    }

    private func reloadFirstPage() {
        storedCount = database.conversationCount()
        conversations = database.page(offset: 0, limit: Self.pageSize)
    }
}
