import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A small SQLite wrapper. `Vault` serializes all access to it.
final class Database {
    enum Value {
        case text(String)
        case int(Int64)
        case blob(Data)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func string(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func blob(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = lastError()
            sqlite3_close(handle)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 3000)
        // Deleted rows are overwritten, and no write-ahead log is left beside the database.
        try execute("PRAGMA secure_delete = ON")
        try execute("PRAGMA journal_mode = DELETE")
        try execute("PRAGMA synchronous = FULL")
        try execute("""
            CREATE TABLE IF NOT EXISTS vault (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                format INTEGER NOT NULL,
                salt BLOB NOT NULL,
                iterations INTEGER NOT NULL,
                password_wrap BLOB NOT NULL,
                recovery_salt BLOB NOT NULL,
                recovery_wrap BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                record BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS journals (
                id TEXT PRIMARY KEY,
                record BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS pages (
                id TEXT PRIMARY KEY,
                slot BLOB NOT NULL UNIQUE,
                record BLOB NOT NULL,
                body BLOB NOT NULL,
                image BLOB NOT NULL
            );
            """)
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    func query<T>(_ sql: String, _ values: [Value] = [], map: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .int(let number):
                sqlite3_bind_int64(statement, index, number)
            case .blob(let data):
                _ = data.withUnsafeBytes { raw in
                    // A zero-length blob still needs a non-null pointer to avoid being stored as NULL.
                    sqlite3_bind_blob(statement, index, raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1),
                                      Int32(raw.count), sqliteTransient)
                }
            }
        }

        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try map(Row(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw lastError()
            }
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    private func lastError() -> VaultError {
        .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "The database could not be opened.")
    }
}
