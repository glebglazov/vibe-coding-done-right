import Foundation
import Darwin

/// Persistent, size-capped log store shared across the app and its extensions
/// via the App Group container.
///
/// Every process writes to the same timeline file while holding an
/// interprocess file lock, so the in-app log viewer sees one chronological
/// stream instead of independently-retained per-process fragments.
///
/// When the file exceeds `maxBytes`, the oldest `trimBytes` worth of **whole
/// lines** are dropped — the cut is aligned to a newline so a line is never
/// split in half.
///
/// All file state is confined to a single serial queue; logging never throws
/// into callers and never blocks the calling thread (writes are enqueued).
final class LogBuffer: @unchecked Sendable {
    static let shared = LogBuffer()

    private let queue = DispatchQueue(label: "com.vcdr.logbuffer", qos: .utility)
    private var storage: Storage?

    private struct Storage {
        let fileURL: URL
        let lockURL: URL
    }

    private nonisolated static let maxBytes = 20 * 1024 * 1024 // 20 MB global cap
    private nonisolated static let trimBytes = maxBytes / 10   // Drop oldest 10% on overflow

    private nonisolated static let appGroupID = "group.glebglazov.vcdr-ios"
    private nonisolated static let logFilename = "vcdr.log"
    private nonisolated static let lockFilename = "vcdr.log.lock"
    private nonisolated static let newline = UInt8(0x0A)
    /// App Group container resolution can contend with launch-time system
    /// services even when dispatched off-main. Persistent capture is
    /// best-effort, so leave the first shell frame completely free and drop
    /// early file lines until storage is ready.
    private nonisolated static let bootstrapDelay: DispatchTimeInterval = .seconds(2)

    /// Fixed-width, lexicographically sortable timestamp — lets the viewer sort
    /// and time-window-filter merged lines with plain string comparison.
    private nonisolated static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        queue.asyncAfter(deadline: .now() + Self.bootstrapDelay) { [self] in
            _ = prepareStorageIfNeeded()
        }
    }

    // MARK: - Write

    func append(category: String, level: String, message: String) {
        let date = Date()
        queue.async { [self] in
            guard let storage else { return }
            let line = "\(Self.timestampFormatter.string(from: date)) [\(category)] [\(level)] \(message)\n"
            withExclusiveFileLock(storage: storage) {
                writeLocked(Data(line.utf8), fileURL: storage.fileURL)
            }
        }
    }

    private func writeLocked(_ data: Data, fileURL: URL) {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if Self.fileSize(fileURL) > Self.maxBytes { trimLocked(fileURL: fileURL) }
        } catch {
            // Logging must never crash or throw into callers; drop on failure.
        }
        try? handle.close()
    }

    /// Drops the oldest `trimBytes` worth of whole lines from the current file.
    private func trimLocked(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL), data.count > Self.trimBytes else { return }
        var cut = Self.trimBytes
        while cut < data.count, data[cut] != Self.newline { cut += 1 }
        if cut < data.count { cut += 1 } // drop the trailing newline too, so we resume on a fresh line
        let kept = data.subdata(in: cut ..< data.count)
        try? kept.write(to: fileURL, options: .atomic)
    }

    // MARK: - File lock

    private func withExclusiveFileLock(storage: Storage, _ body: () -> Void) {
        Self.ensureStorage(fileURL: storage.fileURL, lockURL: storage.lockURL)
        let fd = storage.lockURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }

        body()
    }

    private func prepareStorageIfNeeded() -> Storage? {
        if let storage { return storage }
        let storage = Storage(fileURL: Self.fileURL(), lockURL: Self.lockURL())
        Self.ensureStorage(fileURL: storage.fileURL, lockURL: storage.lockURL)
        self.storage = storage
        return storage
    }

    nonisolated private static func ensureStorage(fileURL: URL, lockURL: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if !fm.fileExists(atPath: lockURL.path) {
            fm.createFile(atPath: lockURL.path, contents: nil)
        }
    }

    nonisolated private static func fileSize(_ url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return size ?? 0
    }

    // MARK: - Read (in-app viewer)

    struct ReadCursor: Equatable, Sendable {
        fileprivate let byteOffset: UInt64
        fileprivate let pendingFragment: String

        nonisolated static let start = ReadCursor(byteOffset: 0, pendingFragment: "")
    }

    struct ReadBatch: Sendable {
        let lines: [String]
        let cursor: ReadCursor
    }

    /// Timestamp string in the same fixed-width format used for stored lines.
    /// Because the format sorts lexicographically, callers can filter by time
    /// window with a plain `>=` comparison against a stored line.
    nonisolated static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Every log line in the shared file, sorted oldest-first.
    nonisolated static func mergedLines() -> [String] {
        (try? String(contentsOf: fileURL(), encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
            ?? []
    }

    /// Reads complete lines appended after `cursor`. If the file was compacted
    /// since the previous read, falls back to a full read and returns a cursor
    /// at the current end of file.
    nonisolated static func readBatch(after cursor: ReadCursor?) -> ReadBatch {
        let fileURL = fileURL()
        let lockURL = lockURL()
        ensureStorage(fileURL: fileURL, lockURL: lockURL)

        return withSharedFileLock(lockURL: lockURL) {
            let fileSize = UInt64(Self.fileSize(fileURL))
            guard let cursor else {
                return fullReadBatch(fileURL: fileURL, fileSize: fileSize)
            }
            guard cursor.byteOffset <= fileSize else {
                return fullReadBatch(fileURL: fileURL, fileSize: fileSize)
            }
            guard cursor.byteOffset < fileSize else {
                return ReadBatch(lines: [], cursor: cursor)
            }

            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                return ReadBatch(lines: [], cursor: cursor)
            }
            do {
                try handle.seek(toOffset: cursor.byteOffset)
                let data = try handle.readToEnd() ?? Data()
                try handle.close()
                let nextCursorOffset = cursor.byteOffset + UInt64(data.count)
                let parsed = parseAppendedLines(data: data, pendingFragment: cursor.pendingFragment)
                return ReadBatch(
                    lines: parsed.lines,
                    cursor: ReadCursor(
                        byteOffset: nextCursorOffset,
                        pendingFragment: parsed.pendingFragment
                    )
                )
            } catch {
                try? handle.close()
                return ReadBatch(lines: [], cursor: cursor)
            }
        } ?? ReadBatch(lines: [], cursor: cursor ?? .start)
    }

    /// Merged log as a single string, for copy / share.
    nonisolated static func mergedSnapshot() -> String {
        mergedLines().joined(separator: "\n")
    }

    nonisolated private static func fullReadBatch(fileURL: URL, fileSize: UInt64) -> ReadBatch {
        let lines = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
            ?? []
        return ReadBatch(
            lines: lines,
            cursor: ReadCursor(byteOffset: fileSize, pendingFragment: "")
        )
    }

    nonisolated private static func parseAppendedLines(
        data: Data,
        pendingFragment: String
    ) -> (lines: [String], pendingFragment: String) {
        guard !data.isEmpty else { return ([], pendingFragment) }

        let appended = String(decoding: data, as: UTF8.self)
        let combined = pendingFragment + appended
        let hasTrailingNewline = data.last == newline
        var pieces = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if hasTrailingNewline {
            if pieces.last == "" { pieces.removeLast() }
            return (pieces.filter { !$0.isEmpty }, "")
        }

        let nextPendingFragment = pieces.popLast() ?? ""
        return (pieces.filter { !$0.isEmpty }, nextPendingFragment)
    }

    nonisolated private static func withSharedFileLock<T>(lockURL: URL, _ body: () -> T) -> T? {
        let fd = lockURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard flock(fd, LOCK_SH) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }

        return body()
    }

    // MARK: - Locations

    nonisolated private static func directory() -> URL {
        let root: URL
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            root = group.appendingPathComponent("VCDR")
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VCDR")
        }
        return root.appendingPathComponent("Logs")
    }

    nonisolated private static func fileURL() -> URL {
        directory().appendingPathComponent(logFilename)
    }

    nonisolated private static func lockURL() -> URL {
        directory().appendingPathComponent(lockFilename)
    }
}
