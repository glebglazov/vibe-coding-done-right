import Foundation
import OSLog

/// A directory of per-record conversation files — the shape the app has always
/// stored history in, and now the transport it syncs through:
///
///   {createdAtISO}_{uuid}.json          ← snapshot
///   {deletedAtISO}_{uuid}.deleted.json  ← tombstone event
///
/// One file per record is what lets a delete be an append-only tombstone
/// instead of an edit to a shared blob, so two devices can merge without a
/// last writer clobbering the other.
///
/// Tombstone suppression: a snapshot is live unless a tombstone exists whose
/// `deletedAt` is at or after the snapshot's file mtime. A later edit on
/// another device (snapshot mtime > `deletedAt`) resurrects the record.
nonisolated struct ConversationFileArchive: Sendable {

    /// A live snapshot file, as `liveEntries()` found it.
    struct Entry: Equatable, Sendable {
        let url: URL
        let id: UUID
        let modifiedAt: Date
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Reading

    /// Every snapshot no tombstone suppresses, newest first.
    func liveEntries() -> [Entry] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var tombstones: [UUID: Date] = [:]
        var snapshots: [Entry] = []

        for url in urls {
            let name = url.lastPathComponent
            guard let modifiedAt = Self.modificationDate(of: url) else { continue }
            if name.hasSuffix(Self.tombstoneSuffix) {
                let base = String(name.dropLast(Self.tombstoneSuffix.count))
                if let id = Self.recordID(fromFilenameBase: base) {
                    if tombstones[id].map({ modifiedAt > $0 }) ?? true {
                        tombstones[id] = modifiedAt
                    }
                }
            } else if name.hasSuffix(Self.snapshotSuffix) {
                let base = String(name.dropLast(Self.snapshotSuffix.count))
                if let id = Self.recordID(fromFilenameBase: base) {
                    snapshots.append(Entry(url: url, id: id, modifiedAt: modifiedAt))
                }
            }
        }

        return snapshots
            .filter { snapshot in
                guard let deletedAt = tombstones[snapshot.id] else { return true }
                return snapshot.modifiedAt > deletedAt
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func readConversation(at url: URL, decoder: JSONDecoder) -> Conversation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Writing

    func writeSnapshot(_ conversation: Conversation, named filename: String, encoder: JSONEncoder) {
        do {
            let data = try encoder.encode(conversation)
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch {
            Logger.history.error("Conversation snapshot write failed: \(error)")
        }
    }

    func writeTombstone(id: UUID, deletedAt: Date, encoder: JSONEncoder) {
        let tombstone = ConversationTombstone(conversationID: id, deletedAt: deletedAt)
        let filename = Self.tombstoneFilename(id: id, deletedAt: deletedAt)
        do {
            let data = try encoder.encode(tombstone)
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch {
            Logger.history.error("Conversation tombstone write failed: \(error)")
        }
    }

    // MARK: - Filenames

    private static let snapshotSuffix = ".json"
    private static let tombstoneSuffix = ".deleted.json"

    static func snapshotFilename(id: UUID, createdAt: Date) -> String {
        "\(filenameTimestamp(createdAt))_\(id.uuidString)\(snapshotSuffix)"
    }

    private static func tombstoneFilename(id: UUID, deletedAt: Date) -> String {
        "\(filenameTimestamp(deletedAt))_\(id.uuidString)\(tombstoneSuffix)"
    }

    private static func recordID(fromFilenameBase base: String) -> UUID? {
        guard let underscore = base.range(of: "_", options: .backwards) else { return nil }
        return UUID(uuidString: String(base[underscore.upperBound...]))
    }

    /// Filesystem-friendly ISO 8601 (colons and dots replaced with dashes).
    /// Lexical order still matches chronological order.
    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
