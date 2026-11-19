import Foundation
import SQLite3

/// Errors raised by the raw SQLite layer (ADR-0016: the system SQLite3
/// C library, no third-party dependency).
struct SQLiteStoreError: Error, Equatable {
    let message: String
    let sql: String?

    static func failure(_ database: OpaquePointer?, sql: String? = nil) -> SQLiteStoreError {
        let text = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite failure"
        return SQLiteStoreError(message: text, sql: sql)
    }
}

/// A thin, synchronous wrapper over the SQLite3 C API — just enough for
/// the library index (open, exec, prepared statements, transactions).
/// Not `Sendable` on purpose: the connection lives inside one actor
/// (`LibraryDatabase`), which is the sole serialized access point.
final class SQLite3Store {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        // `:memory:` (the coordinator's last-resort index) has no parent
        // directory to create.
        if url.path != ":memory:" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let flags =
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let error = SQLiteStoreError.failure(handle, sql: "open \(url.path)")
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Runs one SQL statement with no results (DDL, pragmas, …).
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.failure(handle, sql: sql)
        }
    }

    func prepare(_ sql: String) throws -> SQLite3Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.failure(handle, sql: sql)
        }
        return SQLite3Statement(handle: statement)
    }

    /// Runs `body` inside BEGIN … COMMIT, rolling back on a thrown error.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// True when a table (or virtual table) exists — used by tests to
    /// assert the schema.
    func tableExists(_ name: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT count(*) FROM sqlite_master WHERE type IN ('table','view') AND name = ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int64(statement, 0) == 1 else {
            return false
        }
        return true
    }
}

/// One prepared statement: bind → step loop → reset, finalized on deinit.
final class SQLite3Statement {
    private var handle: OpaquePointer?

    init(handle: OpaquePointer?) {
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    private func failure(_ sql: String? = nil) -> SQLiteStoreError {
        .failure(handle, sql: sql)
    }

    // MARK: binding (1-based positions, matching SQLite)

    func bind(_ position: Int32, _ text: String?) {
        guard let text else {
            sqlite3_bind_null(handle, position)
            return
        }
        sqlite3_bind_text(handle, position, text, -1, sqliteTransient)
    }

    func bind(_ position: Int32, _ value: Double?) {
        guard let value else {
            sqlite3_bind_null(handle, position)
            return
        }
        sqlite3_bind_double(handle, position, value)
    }

    func bind(_ position: Int32, _ value: Int?) {
        guard let value else {
            sqlite3_bind_null(handle, position)
            return
        }
        sqlite3_bind_int64(handle, position, Int64(value))
    }

    // MARK: stepping

    /// Advances one row; false means the statement is exhausted.
    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw failure("step")
        }
    }

    /// Resets bindings so the statement can be reused in a loop.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    // MARK: columns (0-based positions)

    var isNullColumn: (Int32) -> Bool {
        { [self] in sqlite3_column_type(handle, $0) == SQLITE_NULL }
    }

    var textColumn: (Int32) -> String {
        { [self] in sqlite3_column_text(handle, $0).map { String(cString: $0) } ?? "" }
    }

    var doubleColumn: (Int32) -> Double {
        { [self] in sqlite3_column_double(handle, $0) }
    }

    var intColumn: (Int32) -> Int {
        { [self] in Int(sqlite3_column_int64(handle, $0)) }
    }
}

/// The sqliteTransient destructor sentinel for bind calls: SQLite
/// copies bound strings instead of retaining them.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
