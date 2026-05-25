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

    static let maxConversations = 500
    static let pageSize = 50

    // MARK: - State

    private(set) var conversations: [Conversation] = []

    var latestConversation: Conversation? { conversations.first }
    /// Paginate until the UI shows the latest `maxConversations`. Older
    /// conversations remain on disk — never auto-deleted — but are invisible
    /// until a future version exposes a "full history" view.
    var hasMorePages: Bool { cursor < index.count && conversations.count < Self.maxConversations }

    let conversationsDir: URL
    private let legacyFileURL: URL
    // nonisolated(unsafe) — JSONEncoder/Decoder are immutable after init
    // and thread-safe for concurrent encode/decode. Captured by detached
    // tasks that perform disk I/O off MainActor.
    nonisolated(unsafe) private let encoder: JSONEncoder
    nonisolated(unsafe) private let decoder: JSONDecoder

    private struct IndexEntry: Equatable, Sendable {
        let url: URL
        let id: UUID
        let modifiedAt: Date
    }
    private var index: [IndexEntry] = []
    private var cursor: Int = 0

    // MARK: - Init

    init(storageRoot: URL = FileHistoryStore.defaultStorageRoot) {
        self.conversationsDir = storageRoot.appendingPathComponent("conversations")
        self.legacyFileURL = storageRoot.appendingPathComponent("history.json")
        self.encoder = HistoryJSONCoders.makeEncoder()
        self.decoder = HistoryJSONCoders.makeDecoder()

        ensureDirectoryExists()
        migrateLegacyFileIfNeeded()
        rebuildIndex()
        loadNextPage()
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
        Task.detached(priority: .utility) {
            Self.writeSnapshotOffMain(conversation, to: fileURL, encoder: encoder)
        }
    }

    func removeConversation(_ conversation: Conversation) {
        let now = Date()
        let id = conversation.id
        let url = tombstoneURL(id: id, deletedAt: now)
        conversations.removeAll { $0.id == id }
        index.removeAll { $0.id == id }
        cursor = min(cursor, index.count)

        let encoder = self.encoder
        Task.detached(priority: .utility) {
            Self.writeTombstoneOffMain(id: id, deletedAt: now, url: url, encoder: encoder)
        }
    }

    func clearAll() {
        let now = Date()
        var pending: [(id: UUID, url: URL)] = []
        for conv in conversations {
            pending.append((conv.id, tombstoneURL(id: conv.id, deletedAt: now)))
        }
        for entry in index where !conversations.contains(where: { $0.id == entry.id }) {
            pending.append((entry.id, tombstoneURL(id: entry.id, deletedAt: now)))
        }
        conversations.removeAll()
        index.removeAll()
        cursor = 0

        let encoder = self.encoder
        Task.detached(priority: .utility) {
            for item in pending {
                Self.writeTombstoneOffMain(id: item.id, deletedAt: now, url: item.url, encoder: encoder)
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

    /// Async counterpart to `loadNextPage` that moves the synchronous
    /// `Data(contentsOf:)` + JSON decode work onto a utility-priority
    /// detached task. Safe to call from MainActor without stalling the UI,
    /// especially when snapshot files live in an iCloud ubiquity container
    /// where a read can block on placeholder materialization.
    func loadNextPageAsync() async {
        guard hasMorePages else { return }
        let displayCapSlack = Self.maxConversations - conversations.count
        let upper = min(cursor + Self.pageSize, cursor + displayCapSlack, index.count)
        guard cursor < upper else { return }
        let slice = Array(index[cursor..<upper])
        let existingIDs = Set(conversations.map { $0.id })
        let decoder = self.decoder
        let loaded = await Task.detached(priority: .utility) {
            slice.compactMap { entry -> Conversation? in
                guard !existingIDs.contains(entry.id) else { return nil }
                return Self.readConversationOffMain(at: entry.url, decoder: decoder)
            }
        }.value
        conversations.append(contentsOf: loaded)
        cursor = upper
    }

    /// Rescans the on-disk index and reloads the first page of conversations.
    /// Called by `UbiquityHistoryStore` when `NSMetadataQuery` signals remote
    /// changes so the UI picks up newly synced records without a restart.
    ///
    /// The directory scan, per-file mtime lookups, and first-page decodes
    /// all run on a detached utility task so the MainActor stays free while
    /// iCloud resolves placeholders. MainActor state is mutated only on the
    /// hop back at the end.
    func rebuildIndexAndReloadFirstPageAsync() async {
        let dir = conversationsDir
        let newIndex = await Task.detached(priority: .utility) {
            Self.scanIndexOffMain(conversationsDir: dir)
        }.value
        self.index = newIndex
        self.cursor = 0
        self.conversations.removeAll()
        await loadNextPageAsync()
    }

    /// Filenames currently tracked by the index. Used by `UbiquityHistoryStore`
    /// to distinguish "new on disk but not yet applied" files from already-
    /// known ones when probing for pending remote updates.
    var indexedFilenames: Set<String> {
        Set(index.map { $0.url.lastPathComponent })
    }

    // MARK: - Disk I/O

    /// Nonisolated so it can run inside `Task.detached` — callers precompute
    /// the destination URL on MainActor to avoid touching instance state here.
    nonisolated private static func writeSnapshotOffMain(
        _ conversation: Conversation,
        to url: URL,
        encoder: JSONEncoder
    ) {
        do {
            let data = try encoder.encode(conversation)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("FileHistoryStore write snapshot failed: \(error)")
        }
    }

    nonisolated private static func writeTombstoneOffMain(
        id: UUID,
        deletedAt: Date,
        url: URL,
        encoder: JSONEncoder
    ) {
        let tombstone = ConversationTombstone(conversationID: id, deletedAt: deletedAt)
        do {
            let data = try encoder.encode(tombstone)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("FileHistoryStore write tombstone failed: \(error)")
        }
    }

    private func readConversation(at url: URL) -> Conversation? {
        Self.readConversationOffMain(at: url, decoder: decoder)
    }

    /// Nonisolated so it can run inside `Task.detached` during async
    /// pagination — reads a snapshot file and decodes it without touching
    /// instance state.
    nonisolated private static func readConversationOffMain(
        at url: URL,
        decoder: JSONDecoder
    ) -> Conversation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
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
        index = Self.scanIndexOffMain(conversationsDir: conversationsDir)
        cursor = 0
    }

    /// Nonisolated disk scan used by both the synchronous `rebuildIndex`
    /// (called from `init`) and the async refresh path (called from a
    /// detached task). Returns the index directly so callers decide how to
    /// publish it to actor-isolated state.
    nonisolated private static func scanIndexOffMain(conversationsDir: URL) -> [IndexEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var tombstones: [UUID: Date] = [:]
        var snapshots: [(url: URL, id: UUID, modifiedAt: Date)] = []

        for url in urls {
            let name = url.lastPathComponent
            guard let modifiedAt = mtimeOffMain(for: url) else { continue }
            if name.hasSuffix(".deleted.json") {
                let base = String(name.dropLast(".deleted.json".count))
                if let id = extractIDOffMain(from: base) {
                    if tombstones[id].map({ modifiedAt > $0 }) ?? true {
                        tombstones[id] = modifiedAt
                    }
                }
            } else if name.hasSuffix(".json") {
                let base = String(name.dropLast(".json".count))
                if let id = extractIDOffMain(from: base) {
                    snapshots.append((url, id, modifiedAt))
                }
            }
        }

        let live = snapshots.filter { snap in
            guard let tombstoneAt = tombstones[snap.id] else { return true }
            return snap.modifiedAt > tombstoneAt
        }
        return live
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map { IndexEntry(url: $0.url, id: $0.id, modifiedAt: $0.modifiedAt) }
    }

    private func refreshIndexEntry(id: UUID, url: URL, modifiedAt: Date) {
        index.removeAll { $0.id == id }
        index.insert(IndexEntry(url: url, id: id, modifiedAt: modifiedAt), at: 0)
        cursor = min(cursor + 1, index.count)
    }

    // MARK: - Filenames

    private func snapshotURL(id: UUID, createdAt: Date) -> URL {
        conversationsDir.appendingPathComponent("\(Self.filenameTimestamp(createdAt))_\(id.uuidString).json")
    }

    private func tombstoneURL(id: UUID, deletedAt: Date) -> URL {
        conversationsDir.appendingPathComponent("\(Self.filenameTimestamp(deletedAt))_\(id.uuidString).deleted.json")
    }

    nonisolated private static func extractIDOffMain(from base: String) -> UUID? {
        guard let underscore = base.range(of: "_", options: .backwards) else { return nil }
        return UUID(uuidString: String(base[underscore.upperBound...]))
    }

    nonisolated private static func mtimeOffMain(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static let filenameISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Filesystem-friendly ISO 8601 (colons and dots replaced with dashes).
    /// Lexical order still matches chronological order.
    private static func filenameTimestamp(_ date: Date) -> String {
        filenameISO.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    // MARK: - Migration

    private func migrateLegacyFileIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyFileURL.path),
              !fm.fileExists(atPath: conversationsDir.appendingPathComponent(".migrated").path) else {
            return
        }
        guard let data = try? Data(contentsOf: legacyFileURL),
              let legacyConversations = try? decoder.decode([Conversation].self, from: data) else {
            Self.logger.error("FileHistoryStore migration: legacy file present but not decodable")
            return
        }
        ensureDirectoryExists()
        for conv in legacyConversations {
            let url = snapshotURL(id: conv.id, createdAt: conv.lastUpdated)
            Self.writeSnapshotOffMain(conv, to: url, encoder: encoder)
        }
        let backup = legacyFileURL.deletingLastPathComponent().appendingPathComponent("history.json.migrated-backup")
        try? fm.moveItem(at: legacyFileURL, to: backup)
        try? Data().write(to: conversationsDir.appendingPathComponent(".migrated"))
        Self.logger.info("FileHistoryStore migrated \(legacyConversations.count) legacy conversations")
    }

    // MARK: - Logging

    // Routes through the shared `history` channel so these lines land in the
    // persistent log buffer alongside everything else.
    private static let logger = Logger.history

    // MARK: - Filesystem

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: conversationsDir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Storage roots

    /// The root used when sync is disabled or the iCloud container is
    /// unavailable. On macOS: Application Support. On iOS: the App Group
    /// container (falling back to Application Support if the group is missing).
    ///
    /// `UbiquityHistoryStore` uses a different root — the iCloud ubiquity
    /// container — so `localStorageRoot` and `defaultStorageRoot` intentionally
    /// coincide for now. If a separate app-private mirror is ever introduced,
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
