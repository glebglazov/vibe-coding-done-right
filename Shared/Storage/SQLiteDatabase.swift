import Foundation
import SQLite3

/// A single SQLite connection, wrapped just far enough to run statements with
/// bound parameters and read rows back. No schema knowledge lives here — see
/// `ConversationDatabase` for what the history path stores.
///
/// Every entry point takes one recursive lock. SQLite's own serialized mode
/// already makes a shared connection safe call-by-call; the lock is what lets
/// `transaction` hold the connection across several statements, and what keeps
/// a main-actor page read from landing in the middle of a background import's
/// batch.
nonisolated final class SQLiteDatabase: @unchecked Sendable {

    // MARK: - Constants

    /// How long a statement waits for another connection's write lock before
    /// giving up. Reached because conversations and Substitutions open the one
    /// Local Store file as two connections, and their launch bootstraps run at
    /// the same time.
    private static let busyTimeoutMilliseconds: Int32 = 5_000

    /// Tells SQLite to copy a bound value, so Swift's buffer does not have to
    /// outlive the `sqlite3_bind_*` call.
    private static let transientBinding = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    // MARK: - Parameters and rows

    /// A value as SQLite stores it. Callers bind these in statement order.
    enum Value {
        case text(String)
        case int(Int64)
        case double(Double)
        case blob(Data)
    }

    /// One row of a result set, valid only inside the reading closure —
    /// the statement it reads from is finalized when the query returns.
    struct Row {
        fileprivate let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
        }

        func blob(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    // MARK: - Connection

    private let handle: OpaquePointer
    private let lock = NSRecursiveLock()

    /// Opens (creating if needed) the database at `fileURL`, along with the
    /// directory holding it.
    init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(fileURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: status, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - Statements

    /// Runs one or more statements that return nothing — schema setup, pragmas.
    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errorMessage)
            throw SQLiteError(code: status, message: message)
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteError(code: status, message: lastErrorMessage())
        }
    }

    func query<T>(
        _ sql: String,
        _ values: [Value] = [],
        readingEach read: (Row) -> T
    ) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                results.append(read(Row(statement: statement)))
            } else if status == SQLITE_DONE {
                return results
            } else {
                throw SQLiteError(code: status, message: lastErrorMessage())
            }
        }
    }

    /// Runs `body` inside one transaction, rolling back if it throws. Nested
    /// calls join the outer transaction rather than starting a second one.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_get_autocommit(handle) != 0 else { return try body() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Binding

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw SQLiteError(code: status, message: lastErrorMessage())
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch value {
            case .text(let string):
                bound = sqlite3_bind_text(statement, index, string, -1, Self.transientBinding)
            case .int(let number):
                bound = sqlite3_bind_int64(statement, index, number)
            case .double(let number):
                bound = sqlite3_bind_double(statement, index, number)
            case .blob(let data):
                bound = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        buffer.baseAddress,
                        Int32(buffer.count),
                        Self.transientBinding
                    )
                }
            }
            guard bound == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw SQLiteError(code: bound, message: lastErrorMessage())
            }
        }
        return statement
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}

/// What SQLite reported when a statement could not run. Carries the raw code
/// because that is what tells a locked file apart from a corrupt one.
nonisolated struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }

    /// Whether the file itself is unusable, rather than another connection
    /// holding it for a moment. Conversations and Substitutions open the one
    /// Local Store file independently, so a store that discarded the file on a
    /// busy code would throw away a live database.
    var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}
