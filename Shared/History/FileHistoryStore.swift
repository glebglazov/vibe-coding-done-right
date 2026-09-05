import Foundation
import OSLog

/// File-per-record history store. Each conversation lives in its own JSON
/// file so deletes can be modeled as append-only tombstones — enabling future
/// cross-device merges without last-writer-wins on a shared blob.
///
/// Directory layout (under `conversations/`):
///   {createdAtISO}_{uuid}.json          ← snapshot
///   {deletedAtISO}_{uuid}.deleted.json  ← tombstone event
///
/// Tombstone suppression: a snapshot is hidden when a tombstone exists whose
/// `deletedAt` ≥ the snapshot's file mtime. Later edits on another device
/// (snapshot mtime > tombstone.deletedAt) correctly resurrect the record.
@MainActor
@Observable
final class FileHistoryStore: HistoryStore {

    // MARK: - Constants

    nonisolated static let maxConversations = 500
    nonisolated static let pageSize = 50

    // MARK: - State

    private(set) var conversations: [Conversation] = []

    var latestConversation: Conversation? { conversations.first }
    /// Paginate until the UI shows the latest `maxConversations`. Older
    /// conversations remain on disk — never auto-deleted — but are invisible
    /// until a future version exposes a "full history" view.
    var hasMorePages: Bool { cursor < index.count && conversations.count < Self.maxConversations }

    let conversationsDir: URL
    private let archive: ConversationFileArchive
    private let legacyFileURL: URL
    // nonisolated(unsafe) — JSONEncoder/Decoder are immutable after init
    // and thread-safe for concurrent encode/decode. Captured by detached
    // tasks that perform disk I/O off MainActor.
    nonisolated(unsafe) private let encoder: JSONEncoder
    nonisolated(unsafe) private let decoder: JSONDecoder

    /// One shape for the on-disk record layout: the archive owns the
    /// filenames, the tombstone suppression and the entries both this store
    /// and the Local Store's import path read.
    fileprivate typealias IndexEntry = ConversationFileArchive.Entry
    private var index: [IndexEntry] = []
    private var cursor: Int = 0

    /// Sendable payload produced off the main actor by `loadSnapshot`. The
    /// `@MainActor` store is then installed from this cheaply — no filesystem,
    /// directory scan, or decode work belongs in `init`.
    struct Snapshot: Sendable {
        let storageRoot: URL
        fileprivate let index: [IndexEntry]
        fileprivate let conversations: [Conversation]
        fileprivate let cursor: Int
    }

    // MARK: - Init

    /// Constructs from a pre-loaded `Snapshot`. Performs no filesystem or
    /// iCloud work — callers must build the snapshot off the main actor via
    /// `loadSnapshot(storageRoot:)`.
    init(snapshot: Snapshot) {
        self.conversationsDir = snapshot.storageRoot.appendingPathComponent("conversations")
        self.archive = ConversationFileArchive(directory: conversationsDir)
        self.legacyFileURL = snapshot.storageRoot.appendingPathComponent("history.json")
        self.encoder = HistoryJSONCoders.makeEncoder()
        self.decoder = HistoryJSONCoders.makeDecoder()
        self.index = snapshot.index
        self.conversations = snapshot.conversations
        self.cursor = snapshot.cursor
    }

    /// Scans the storage root, migrates legacy data if needed, and decodes the
    /// first page. Safe to call from any thread; pair with `init(snapshot:)`
    /// on the main actor.
    nonisolated static func loadSnapshot(
        storageRoot: URL = FileHistoryStore.defaultStorageRoot
    ) -> Snapshot {
        let conversationsDir = storageRoot.appendingPathComponent("conversations")
        let legacyFileURL = storageRoot.appendingPathComponent("history.json")
        let encoder = HistoryJSONCoders.makeEncoder()
        let decoder = HistoryJSONCoders.makeDecoder()

        let archive = ConversationFileArchive(directory: conversationsDir)
        archive.ensureDirectoryExists()
        migrateLegacyFileIfNeededOffMain(
            legacyFileURL: legacyFileURL,
            archive: archive,
            encoder: encoder,
            decoder: decoder
        )
        let index = archive.liveEntries()
        let (conversations, cursor) = loadFirstPageOffMain(index: index, decoder: decoder)
        return Snapshot(
            storageRoot: storageRoot,
            index: index,
            conversations: conversations,
            cursor: cursor
        )
    }

    // MARK: - HistoryStore

    func record(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        label: String?
    ) {
        let now = Date()
        let existing = loadConversation(id: conversationID)
        let conversation: Conversation
        let fileURL: URL

        if let (prior, priorURL) = existing {
            var updated = prior
            updated.inputSegments = inputSegments
            updated.output = output
            updated.label = label
            updated.lastUpdated = now
            conversation = updated
            fileURL = priorURL
        } else {
            conversation = Conversation(
                id: conversationID,
                inputSegments: inputSegments,
                output: output,
                label: label,
                lastUpdated: now
            )
            fileURL = snapshotURL(id: conversationID, createdAt: now)
        }

        // Update in-memory state synchronously so UI reflects the new entry
        // immediately. Disk I/O is dispatched off MainActor below — blocking
        // here would stall Darwin handlers (settings sync) and the keyboard's
        // cross-process stateKey poll.
        if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations.remove(at: idx)
        }
        conversations.insert(conversation, at: 0)
        refreshIndexEntry(id: conversationID, url: fileURL, modifiedAt: now)

        let encoder = self.encoder
        let archive = self.archive
        let filename = fileURL.lastPathComponent
        Task.detached(priority: .utility) {
            archive.writeSnapshot(conversation, named: filename, encoder: encoder)
        }
    }

    func removeConversation(_ conversation: Conversation) {
        let now = Date()
        let id = conversation.id
        conversations.removeAll { $0.id == id }
        index.removeAll { $0.id == id }
        cursor = min(cursor, index.count)

        let encoder = self.encoder
        let archive = self.archive
        Task.detached(priority: .utility) {
            archive.writeTombstone(id: id, deletedAt: now, encoder: encoder)
        }
    }

    func clearAll() {
        let now = Date()
        var pending: [UUID] = conversations.map(\.id)
        for entry in index where !conversations.contains(where: { $0.id == entry.id }) {
            pending.append(entry.id)
        }
        conversations.removeAll()
        index.removeAll()
        cursor = 0

        let encoder = self.encoder
        let archive = self.archive
        Task.detached(priority: .utility) {
            for id in pending {
                archive.writeTombstone(id: id, deletedAt: now, encoder: encoder)
            }
        }
    }

    func loadNextPage() {
        guard hasMorePages else { return }
        // Cap loading so `conversations` never grows past `maxConversations`.
        // Index entries beyond that point stay on disk but are invisible
        // until a future release exposes older history.
        let displayCapSlack = Self.maxConversations - conversations.count
        let upper = min(cursor + Self.pageSize, cursor + displayCapSlack, index.count)
        guard cursor < upper else { return }
        var loaded: [Conversation] = []
        for i in cursor..<upper {
            guard !conversations.contains(where: { $0.id == index[i].id }),
                  let conv = readConversation(at: index[i].url) else { continue }
            loaded.append(conv)
        }
        conversations.append(contentsOf: loaded)
        cursor = upper
    }

    // MARK: - Disk I/O

    private func readConversation(at url: URL) -> Conversation? {
        ConversationFileArchive.readConversation(at: url, decoder: decoder)
    }

    /// Decodes the first page of conversations from a freshly scanned index.
    /// Used by `loadSnapshot` so the MainActor init never touches disk.
    nonisolated private static func loadFirstPageOffMain(
        index: [IndexEntry],
        decoder: JSONDecoder
    ) -> (conversations: [Conversation], cursor: Int) {
        let upper = min(Self.pageSize, Self.maxConversations, index.count)
        var loaded: [Conversation] = []
        for i in 0..<upper {
            guard let conv = ConversationFileArchive.readConversation(
                at: index[i].url,
                decoder: decoder
            ) else { continue }
            loaded.append(conv)
        }
        return (loaded, upper)
    }

    private func loadConversation(id: UUID) -> (Conversation, URL)? {
        if let inMemory = conversations.first(where: { $0.id == id }),
           let entry = index.first(where: { $0.id == id }) {
            return (inMemory, entry.url)
        }
        if let entry = index.first(where: { $0.id == id }),
           let conv = readConversation(at: entry.url) {
            return (conv, entry.url)
        }
        return nil
    }

    // MARK: - Index

    func rebuildIndex() {
        index = archive.liveEntries()
        cursor = 0
    }

    private func refreshIndexEntry(id: UUID, url: URL, modifiedAt: Date) {
        index.removeAll { $0.id == id }
        index.insert(IndexEntry(url: url, id: id, modifiedAt: modifiedAt), at: 0)
        cursor = min(cursor + 1, index.count)
    }

    // MARK: - Filenames

    private func snapshotURL(id: UUID, createdAt: Date) -> URL {
        conversationsDir.appendingPathComponent(
            ConversationFileArchive.snapshotFilename(id: id, createdAt: createdAt)
        )
    }

    // MARK: - Migration

    nonisolated private static func migrateLegacyFileIfNeededOffMain(
        legacyFileURL: URL,
        archive: ConversationFileArchive,
        encoder: JSONEncoder,
        decoder: JSONDecoder
    ) {
        let fm = FileManager.default
        let migratedMarker = archive.directory.appendingPathComponent(".migrated")
        guard fm.fileExists(atPath: legacyFileURL.path),
              !fm.fileExists(atPath: migratedMarker.path) else {
            return
        }
        guard let data = try? Data(contentsOf: legacyFileURL),
              let legacyConversations = try? decoder.decode([Conversation].self, from: data) else {
            Self.logger.error("FileHistoryStore migration: legacy file present but not decodable")
            return
        }
        archive.ensureDirectoryExists()
        for conv in legacyConversations {
            archive.writeSnapshot(
                conv,
                named: ConversationFileArchive.snapshotFilename(id: conv.id, createdAt: conv.lastUpdated),
                encoder: encoder
            )
        }
        let backup = legacyFileURL.deletingLastPathComponent()
            .appendingPathComponent("history.json.migrated-backup")
        try? fm.moveItem(at: legacyFileURL, to: backup)
        try? Data().write(to: migratedMarker)
        Self.logger.info("FileHistoryStore migrated \(legacyConversations.count) legacy conversations")
    }

    // MARK: - Logging

    // Routes through the shared `history` channel so these lines land in the
    // persistent log buffer alongside everything else.
    nonisolated private static let logger = Logger.history

    // MARK: - Storage roots

    /// The root used when sync is disabled or the iCloud container is
    /// unavailable. On macOS: Application Support. On iOS: the App Group
    /// container (falling back to Application Support if the group is missing).
    ///
    /// `localStorageRoot` and `defaultStorageRoot` intentionally coincide for
    /// now. If a separate app-private mirror is ever introduced,
    /// `localStorageRoot` is the extension point.
    nonisolated static var localStorageRoot: URL {
        #if os(macOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VCDR")
        #else
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.glebglazov.vcdr-ios"
        ) {
            return group.appendingPathComponent("VCDR")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VCDR")
        #endif
    }

    nonisolated static var defaultStorageRoot: URL { localStorageRoot }
}
