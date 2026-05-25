import Foundation

/// Persistent, size-capped log store shared across the app and its extensions
/// via the App Group container.
///
/// Each process writes its **own** file (named after its bundle identifier) so
/// the app and keyboard extension never race on the same file handle. The
/// in-app log viewer merges every `*.log` file in the directory and sorts by
/// the line's timestamp prefix.
///
/// When a process's file exceeds `maxBytes`, the oldest `trimBytes` worth of
/// **whole lines** are dropped — the cut is aligned to a newline so a line is
/// never split in half.
///
/// All file state is confined to a single serial queue; logging never throws
/// into callers and never blocks the calling thread (writes are enqueued).
final class LogBuffer: @unchecked Sendable {
    static let shared = LogBuffer()

    private let queue = DispatchQueue(label: "com.vcdr.logbuffer", qos: .utility)
    private let fileURL: URL
    private var handle: FileHandle?
    private var bytesOnDisk = 0

    private let maxBytes = 5 * 1024 * 1024   // 5 MB per-process cap
    private let trimBytes = 1 * 1024 * 1024  // drop oldest 1 MB (line-aligned) on overflow

    private static let appGroupID = "group.glebglazov.vcdr-ios"

    /// Fixed-width, lexicographically sortable timestamp — lets the viewer sort
    /// and time-window-filter merged lines with plain string comparison.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        fileURL = Self.fileURL(forProcess: Bundle.main.bundleIdentifier ?? "vcdr")
        queue.sync { openHandle() }
    }

    // MARK: - Write

    func append(category: String, level: String, message: String) {
        let date = Date()
        queue.async { [self] in
            let line = "\(Self.timestampFormatter.string(from: date)) [\(category)] [\(level)] \(message)\n"
            write(Data(line.utf8))
        }
    }

    private func write(_ data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesOnDisk += data.count
            if bytesOnDisk > maxBytes { trim() }
        } catch {
            // Logging must never crash or throw into callers; drop on failure.
        }
    }

    /// Drops the oldest `trimBytes` worth of whole lines from the current file.
    private func trim() {
        guard let data = try? Data(contentsOf: fileURL), data.count > trimBytes else { return }
        let newline = UInt8(0x0A)
        var cut = trimBytes
        while cut < data.count, data[cut] != newline { cut += 1 }
        if cut < data.count { cut += 1 } // drop the trailing newline too, so we resume on a fresh line
        let kept = data.subdata(in: cut ..< data.count)
        try? handle?.close()
        try? kept.write(to: fileURL, options: .atomic)
        openHandle()
    }

    // MARK: - File handle

    private func openHandle() {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: fileURL)
        handle = h
        if let h, let end = try? h.seekToEnd() {
            bytesOnDisk = Int(end)
        } else {
            bytesOnDisk = 0
        }
    }

    // MARK: - Read (in-app viewer)

    /// Timestamp string in the same fixed-width format used for stored lines.
    /// Because the format sorts lexicographically, callers can filter by time
    /// window with a plain `>=` comparison against a stored line.
    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Every log line across all processes' files, sorted oldest-first.
    static func mergedLines() -> [String] {
        files()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
            .sorted()
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

    private static func fileURL(forProcess id: String) -> URL {
        directory().appendingPathComponent("\(id).log")
    }

    private static func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "log" } ?? []
    }
}
