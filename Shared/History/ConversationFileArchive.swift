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

    /// A live snapshot file, as a scan found it.
    struct Entry: Equatable, Sendable {
        let url: URL
        let id: UUID
        let modifiedAt: Date
    }

    /// A delete some device made, as the tombstone file that records it.
    struct Tombstone: Equatable, Sendable {
        let id: UUID
        let deletedAt: Date
    }

    /// What one read of the directory found: the records that are still live,
    /// and the deletes that decided which ones are not.
    struct Scan: Sendable {
        let entries: [Entry]
        let tombstones: [Tombstone]
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
        scan().entries
    }

    /// Reads the directory once.
    ///
    /// - Parameter modifiedAfter: the replication window's cutoff — files
    ///   older than it are not read at all. Nil reads everything.
    func scan(modifiedAfter cutoff: Date? = nil) -> Scan {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Scan(entries: [], tombstones: [])
        }

        var tombstones: [UUID: Date] = [:]
        var snapshots: [Entry] = []

        for url in urls {
            let name = url.lastPathComponent
            guard let modifiedAt = Self.modificationDate(of: url) else { continue }
            if let cutoff, modifiedAt < cutoff { continue }
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

        let live = snapshots
            .filter { snapshot in
                guard let deletedAt = tombstones[snapshot.id] else { return true }
                return snapshot.modifiedAt > deletedAt
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        return Scan(
            entries: live,
            tombstones: tombstones.map { Tombstone(id: $0.key, deletedAt: $0.value) }
        )
    }

    static func readConversation(at url: URL, decoder: JSONDecoder) -> Conversation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Writing

    /// - Returns: whether the file is now in the directory. A refused write —
    ///   an unreachable container, a directory that is not there — leaves the
    ///   record owing its file, which is what makes the next drain retry it
    ///   instead of dropping the record.
    @discardableResult
    func writeSnapshot(_ conversation: Conversation, named filename: String, encoder: JSONEncoder) -> Bool {
        do {
            let data = try encoder.encode(conversation)
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            return true
        } catch {
            Logger.history.error("Conversation snapshot write failed: \(error)")
            return false
        }
    }

    /// - Returns: whether the tombstone is now in the directory, on the same
    ///   terms as `writeSnapshot`.
    @discardableResult
    func writeTombstone(id: UUID, deletedAt: Date, encoder: JSONEncoder) -> Bool {
        let tombstone = ConversationTombstone(conversationID: id, deletedAt: deletedAt)
        let filename = Self.tombstoneFilename(id: id, deletedAt: deletedAt)
        do {
            let data = try encoder.encode(tombstone)
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            return true
        } catch {
            Logger.history.error("Conversation tombstone write failed: \(error)")
            return false
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

    /// The capture time the leading stamp of a snapshot filename carries.
    ///
    /// Records predating the `capturedAt` field carry it nowhere else, and the
    /// name never changes once written, so this is what tells the Local Store
    /// when an imported conversation was dictated.
    static func captureTime(fromFilename name: String) -> Date? {
        guard name.hasSuffix(snapshotSuffix) else { return nil }
        let base = name.dropLast(snapshotSuffix.count)
        guard let underscore = base.range(of: "_", options: .backwards) else { return nil }
        return date(fromFilenameTimestamp: String(base[..<underscore.lowerBound]))
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

    /// Undoes `filenameTimestamp`. The dashes standing in for the time's colons
    /// and dot are the only ones after the `T`, so putting them back is a
    /// matter of counting fields — three for a whole-second stamp, which older
    /// versions wrote, four once fractional seconds arrived.
    private static func date(fromFilenameTimestamp stamp: String) -> Date? {
        let halves = stamp.split(separator: "T", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let fields = halves[1].split(separator: "-")
        let time: String
        switch fields.count {
        case 3: time = "\(fields[0]):\(fields[1]):\(fields[2])"
        case 4: time = "\(fields[0]):\(fields[1]):\(fields[2]).\(fields[3])"
        default: return nil
        }
        let iso = "\(halves[0])T\(time)"
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}
