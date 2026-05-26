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
    private let fileURL: URL
    private let lockURL: URL

    private static let maxBytes = 20 * 1024 * 1024 // 20 MB global cap
    private static let trimBytes = maxBytes / 10   // Drop oldest 10% on overflow

    private static let appGroupID = "group.glebglazov.vcdr-ios"
    private static let logFilename = "vcdr.log"
    private static let lockFilename = "vcdr.log.lock"

    /// Fixed-width, lexicographically sortable timestamp — lets the viewer sort
    /// and time-window-filter merged lines with plain string comparison.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        fileURL = Self.fileURL()
        lockURL = Self.lockURL()
        queue.sync { Self.ensureStorage(fileURL: fileURL, lockURL: lockURL) }
    }

    // MARK: - Write

    func append(category: String, level: String, message: String) {
        let date = Date()
        queue.async { [self] in
            let line = "\(Self.timestampFormatter.string(from: date)) [\(category)] [\(level)] \(message)\n"
            withExclusiveFileLock {
                writeLocked(Data(line.utf8))
            }
        }
    }

    private func writeLocked(_ data: Data) {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if Self.fileSize(fileURL) > Self.maxBytes { trimLocked() }
        } catch {
            // Logging must never crash or throw into callers; drop on failure.
        }
        try? handle.close()
    }

    /// Drops the oldest `trimBytes` worth of whole lines from the current file.
    private func trimLocked() {
        guard let data = try? Data(contentsOf: fileURL), data.count > Self.trimBytes else { return }
        let newline = UInt8(0x0A)
        var cut = Self.trimBytes
        while cut < data.count, data[cut] != newline { cut += 1 }
        if cut < data.count { cut += 1 } // drop the trailing newline too, so we resume on a fresh line
        let kept = data.subdata(in: cut ..< data.count)
        try? kept.write(to: fileURL, options: .atomic)
    }

    // MARK: - File lock

    private func withExclusiveFileLock(_ body: () -> Void) {
        Self.ensureStorage(fileURL: fileURL, lockURL: lockURL)
        let fd = lockURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }

        body()
    }

    private static func ensureStorage(fileURL: URL, lockURL: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if !fm.fileExists(atPath: lockURL.path) {
            fm.createFile(atPath: lockURL.path, contents: nil)
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return size ?? 0
    }

    // MARK: - Read (in-app viewer)

    /// Timestamp string in the same fixed-width format used for stored lines.
    /// Because the format sorts lexicographically, callers can filter by time
    /// window with a plain `>=` comparison against a stored line.
    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Every log line in the shared file, sorted oldest-first.
    static func mergedLines() -> [String] {
        (try? String(contentsOf: fileURL(), encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
            ?? []
    }

    /// Merged log as a single string, for copy / share.
    static func mergedSnapshot() -> String {
        mergedLines().joined(separator: "\n")
    }

    // MARK: - Locations

    private static func directory() -> URL {
        let root: URL
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            root = group.appendingPathComponent("VCDR")
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VCDR")
        }
        return root.appendingPathComponent("Logs")
    }

    private static func fileURL() -> URL {
        directory().appendingPathComponent(logFilename)
    }

    private static func lockURL() -> URL {
        directory().appendingPathComponent(lockFilename)
    }
}
