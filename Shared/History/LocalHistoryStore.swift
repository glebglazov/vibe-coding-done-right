import Foundation
import OSLog

/// The history store every read answers from: launch, the list and paging all
/// come out of the on-device `ConversationDatabase`, never out of iCloud.
///
/// The record files stay the sync transport. A write lands in the database
/// first and is exported to a file behind it, so a dictation is recorded at
/// local-disk speed and the other devices converge as they always did. The
/// directory those files live in is handed over *after* the store is readable
/// — resolving the iCloud container takes seconds on a first launch, and no
/// read waits for it (see `docs/adr/0010`).
@MainActor
@Observable
final class LocalHistoryStore: HistoryStore, RecordFileSyncedStore {

    // MARK: - Constants

    /// How far back the list pages before it stops. Older conversations stay
    /// in the database — never deleted — but stay invisible until a future
    /// version exposes a full-history view.
    nonisolated static let maxConversations = 500
    nonisolated static let pageSize = 50

    // MARK: - State

    private(set) var conversations: [Conversation] = []
    private(set) var discardedCount: Int
    private(set) var latestConversation: Conversation?

    var filter: HistoryFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            reloadFirstPage()
        }
    }

    var hasMorePages: Bool { conversations.count < min(storedCount, Self.maxConversations) }

    private let database: ConversationDatabase
    /// How many conversations the filter admits in the database, loaded or
    /// not. This tells the list whether another page exists.
    private var storedCount: Int
    /// The record files this store exports to. Nil until `syncRecordFiles`
    /// hands over the directory; writes made before then are remembered by the
    /// database and exported by the first drain.
    private var recordFiles: ConversationFileArchive?

    /// Sendable payload produced off the main actor by `loadSnapshot`. The
    /// `@MainActor` store is installed from it without touching disk.
    struct Snapshot: Sendable {
        let database: ConversationDatabase
        let conversations: [Conversation]
        let storedCount: Int
        let discardedCount: Int
        let latestConversation: Conversation?
    }

    // MARK: - Init

    /// Constructs from a pre-loaded `Snapshot`. Performs no I/O.
    init(snapshot: Snapshot) {
        self.database = snapshot.database
        self.conversations = snapshot.conversations
        self.storedCount = snapshot.storedCount
        self.discardedCount = snapshot.discardedCount
        self.latestConversation = snapshot.latestConversation
    }

    /// Opens the database and reads the first page. Local disk only — nothing
    /// here can block on iCloud — but blocking all the same, so callers run it
    /// off the cooperative pool and pair it with `init(snapshot:)`.
    nonisolated static func loadSnapshot(
        fileURL: URL = LocalStoreFile.url
    ) throws -> Snapshot {
        let database = try openDatabase(at: fileURL)
        return Snapshot(
            database: database,
            conversations: database.page(offset: 0, limit: pageSize),
            storedCount: database.conversationCount(),
            discardedCount: database.conversationCount(filter: .discarded),
            latestConversation: database.newestNormal()
        )
    }

    nonisolated private static func openDatabase(at fileURL: URL) throws -> ConversationDatabase {
        do {
            return try ConversationDatabase(fileURL: fileURL)
        } catch let error as SQLiteError where error.isCorruption {
            // The record files still hold every record, so discarding a corrupt
            // database costs one re-import rather than the history itself.
            Logger.history.error("Local store corrupt, rebuilding: \(error)")
            LocalStoreFile.discardCorruptDatabase(at: fileURL)
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
        write(conversationID) {
            $0.inputSegments = inputSegments
            $0.output = output
            $0.label = label
            $0.status = .normal
        }
    }

    func recordDiscarded(
        conversationID: UUID,
        inputSegments: [InputSegment],
        choice: RecordedOutputChoice
    ) {
        write(conversationID) {
            $0.inputSegments = inputSegments
            $0.output = nil
            $0.label = nil
            $0.status = .discarded(choice)
        }
    }

    func resolveDiscarded(conversationID: UUID, output: String, label: String?) {
        guard database.stored(id: conversationID) != nil else { return }
        write(conversationID) {
            $0.output = output
            $0.label = label
            $0.status = .normal
        }
    }

    func removeConversation(id: UUID) {
        guard database.stored(id: id) != nil else { return }
        database.delete(id: id, deletedAt: Date())
        conversations.removeAll { $0.id == id }
        refreshDatabaseReads()
        exportPendingRecords()
    }

    /// Every stored conversation that `matches`, loaded or not. The whole
    /// database is decoded on a GCD thread, so the list stays responsive.
    func conversationIDs(matching matches: @escaping @Sendable (Conversation) -> Bool) async -> [UUID] {
        let database = database
        return await withBlockingTask(qos: .utility) {
            database.conversationIDs(matching: matches)
        }
    }

    func clearAll() {
        database.deleteAll(deletedAt: Date())
        conversations.removeAll()
        refreshDatabaseReads()
        exportPendingRecords()
    }

    func loadNextPage() {
        guard hasMorePages else { return }
        let limit = min(Self.pageSize, Self.maxConversations - conversations.count)
        let loaded = database.page(offset: conversations.count, limit: limit, filter: filter)
        // A record written since the last page shifted the window by one, so
        // the page can repeat a conversation the list already shows.
        let known = Set(conversations.map(\.id))
        conversations.append(contentsOf: loaded.filter { !known.contains($0.id) })
    }

    /// Creates or edits one conversation in the database, then shows the
    /// result in the list as the filter admits it.
    private func write(_ id: UUID, applying edit: (inout Conversation) -> Void) {
        let now = Date()
        let stored = database.stored(id: id)
        var conversation = stored?.conversation
            ?? Conversation(id: id, inputSegments: [], output: nil, label: nil, lastUpdated: now)
        edit(&conversation)
        conversation.lastUpdated = now
        // An edit rewrites the file the record already occupies, so the
        // container never grows a second file for one conversation.
        let filename = stored?.filename
            ?? ConversationFileArchive.snapshotFilename(id: id, createdAt: now)
        database.save(conversation, filename: filename)

        // The list is ordered by capture time, which an edit does not move, so
        // an edited conversation stays where it is instead of jumping to the top.
        let index = conversations.firstIndex { $0.id == id }
        switch (index, filter.admits(conversation)) {
        case (let index?, true): conversations[index] = conversation
        case (let index?, false): conversations.remove(at: index)
        case (nil, true) where stored == nil: conversations.insert(conversation, at: 0)
        default: break
        }
        refreshDatabaseReads()
        exportPendingRecords()
    }

    /// Everything the store answers from the database rather than from the
    /// loaded page, read again after each write or merge.
    private func refreshDatabaseReads() {
        storedCount = database.conversationCount(filter: filter)
        discardedCount = database.conversationCount(filter: .discarded)
        latestConversation = database.newestNormal()
    }

    // MARK: - Record files

    /// Brings a directory of record files into the database, writes out
    /// whatever the database still owes it, and republishes the list.
    ///
    /// - Returns: the records the directory would not take, which is the part
    ///   of a pass's Outstanding Work only the database can see.
    @discardableResult
    func syncRecordFiles(in directory: URL) async -> OutstandingWork {
        let database = self.database
        let archive = ConversationFileArchive(directory: directory)
        let stillOwing = await withBlockingTask(qos: .utility) { () -> Int in
            archive.ensureDirectoryExists()
            HistoryImporter.merge(from: archive, into: database)
            return HistoryExporter.drain(database, to: archive)
        }
        recordFiles = archive
        reloadFirstPage()
        return OutstandingWork(rowsAwaitingExport: stillOwing)
    }

    private func exportPendingRecords() {
        guard let recordFiles else { return }
        let database = self.database
        // The drain blocks on the iCloud daemon, so it takes a GCD thread
        // rather than one of the cooperative pool's few (ADR-0003).
        Task {
            await withBlockingTask(qos: .utility) {
                HistoryExporter.drain(database, to: recordFiles)
            }
        }
    }

    private func reloadFirstPage() {
        refreshDatabaseReads()
        conversations = database.page(offset: 0, limit: Self.pageSize, filter: filter)
    }
}
