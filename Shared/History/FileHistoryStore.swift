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
    var hasMorePages: Bool { cursor < index.count }

    private let conversationsDir: URL
    private let legacyFileURL: URL
    // nonisolated(unsafe) — JSONEncoder/Decoder are immutable after init
    // and thread-safe for concurrent encode/decode. Captured by detached
    // tasks that perform disk I/O off MainActor.
    nonisolated(unsafe) private let encoder: JSONEncoder
    nonisolated(unsafe) private let decoder: JSONDecoder

    private struct IndexEntry: Equatable {
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
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()

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
        let excessURLs = trimRetentionInMemory()

        let encoder = self.encoder
        Task.detached(priority: .utility) {
            Self.writeSnapshotOffMain(conversation, to: fileURL, encoder: encoder)
            for url in excessURLs {
                try? FileManager.default.removeItem(at: url)
            }
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
        let upper = min(cursor + Self.pageSize, index.count)
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

    private func rebuildIndex() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            index = []
            return
        }

        var tombstones: [UUID: Date] = [:]
        var snapshots: [(url: URL, id: UUID, modifiedAt: Date)] = []

        for url in urls {
            let name = url.lastPathComponent
            guard let modifiedAt = mtime(for: url) else { continue }
            if name.hasSuffix(".deleted.json") {
                let base = String(name.dropLast(".deleted.json".count))
                if let id = extractID(from: base) {
                    if tombstones[id].map({ modifiedAt > $0 }) ?? true {
                        tombstones[id] = modifiedAt
                    }
                }
            } else if name.hasSuffix(".json") {
                let base = String(name.dropLast(".json".count))
                if let id = extractID(from: base) {
                    snapshots.append((url, id, modifiedAt))
                }
            }
        }

        let live = snapshots.filter { snap in
            guard let tombstoneAt = tombstones[snap.id] else { return true }
            return snap.modifiedAt > tombstoneAt
        }
        index = live
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map { IndexEntry(url: $0.url, id: $0.id, modifiedAt: $0.modifiedAt) }
        cursor = 0
    }

    private func refreshIndexEntry(id: UUID, url: URL, modifiedAt: Date) {
        index.removeAll { $0.id == id }
        index.insert(IndexEntry(url: url, id: id, modifiedAt: modifiedAt), at: 0)
        cursor = min(cursor + 1, index.count)
    }

    /// Trims in-memory index + conversations to the retention cap and returns
    /// the URLs that need to be deleted from disk. The caller performs the
    /// `FileManager.removeItem` calls off MainActor.
    private func trimRetentionInMemory() -> [URL] {
        guard index.count > Self.maxConversations else { return [] }
        let excess = index.count - Self.maxConversations
        let toDrop = Array(index.suffix(excess))
        index.removeLast(excess)
        if conversations.count > Self.maxConversations {
            conversations = Array(conversations.prefix(Self.maxConversations))
        }
        cursor = min(cursor, index.count)
        return toDrop.map { $0.url }
    }

    // MARK: - Filenames

    private func snapshotURL(id: UUID, createdAt: Date) -> URL {
        conversationsDir.appendingPathComponent("\(Self.filenameTimestamp(createdAt))_\(id.uuidString).json")
    }

    private func tombstoneURL(id: UUID, deletedAt: Date) -> URL {
        conversationsDir.appendingPathComponent("\(Self.filenameTimestamp(deletedAt))_\(id.uuidString).deleted.json")
    }

    private func extractID(from base: String) -> UUID? {
        guard let underscore = base.range(of: "_", options: .backwards) else { return nil }
        return UUID(uuidString: String(base[underscore.upperBound...]))
    }

    private func mtime(for url: URL) -> Date? {
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
        Self.logger.info("FileHistoryStore migrated \(legacyConversations.count, privacy: .public) legacy conversations")
    }

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "vcdr.history",
        category: "history"
    )

    // MARK: - Filesystem

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: conversationsDir,
            withIntermediateDirectories: true
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Accept either ISO 8601 strings (new format) or TimeInterval-since-
        // reference-date doubles (legacy files written with the default
        // JSONEncoder date strategy). The legacy fallback keeps pre-migration
        // on-disk files readable without a one-shot rewrite.
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            if let str = try? container.decode(String.self) {
                if let date = iso.date(from: str) { return date }
                let isoNoFraction = ISO8601DateFormatter()
                if let date = isoNoFraction.date(from: str) { return date }
            }
            if let interval = try? container.decode(TimeInterval.self) {
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format"
            )
        }
        return decoder
    }

    // MARK: - Default storage root

    nonisolated static var defaultStorageRoot: URL {
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
}
