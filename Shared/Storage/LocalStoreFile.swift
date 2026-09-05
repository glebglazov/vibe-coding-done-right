import Foundation

/// Where the device's Local Store lives: one SQLite file holding conversations
/// and Substitutions in tables of their own.
///
/// Never in the iCloud container. SQLite with a WAL is several files mutating
/// constantly, and iCloud file coordination resolves a conflict between them as
/// a corrupted database rather than a merge, so records sync and the database
/// does not (see `docs/adr/0010`). `FileHistoryStore.localStorageRoot` is the
/// app's own storage: the app group on iOS, Application Support on macOS.
///
/// The file is still named for history, which opened it first. Renaming it
/// would mean moving it out from under two launch-time opens that race each
/// other, for nothing a reader of this file learns anyway.
nonisolated enum LocalStoreFile {
    static var url: URL {
        FileHistoryStore.localStorageRoot.appendingPathComponent("history.sqlite3")
    }

    /// Removes a database SQLite refuses to open, along with the WAL and shared
    /// memory files that belong to it, so the next attempt gets a fresh one.
    static func discardCorruptDatabase(at fileURL: URL) {
        for sibling in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fileURL.path + sibling))
        }
    }
}
