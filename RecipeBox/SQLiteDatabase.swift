import Foundation
import SQLite3

/// A thin wrapper over the SQLite C API that ships with iOS — no packages to
/// add. Just enough for this app: run statements with bound parameters, read
/// rows, run a group of statements as one transaction.
///
/// Not thread-safe by itself; RecipeLibrary funnels every call through one
/// serial queue.
final class SQLiteDatabase {

    enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
        case null

        static func optional(_ string: String?) -> Value {
            if let string, !string.isEmpty { return .text(string) }
            return .null
        }
        static func uuid(_ id: UUID?) -> Value {
            id.map { .text($0.uuidString) } ?? .null
        }
    }

    struct SQLiteError: LocalizedError {
        let message: String
        var errorDescription: String? { "Database error: \(message)" }
    }

    /// One result row; column indexes start at 0.
    struct Row {
        fileprivate let statement: OpaquePointer

        func string(_ column: Int32) -> String {
            guard let c = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: c)
        }
        func optionalString(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : string(column)
        }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func uuid(_ column: Int32) -> UUID? {
            optionalString(column).flatMap { UUID(uuidString: $0) }
        }
    }

    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open the database"
            sqlite3_close(handle)
            throw SQLiteError(message: message)
        }
        try run("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    // MARK: - Running statements

    /// Runs one or more statements with no parameters (schema scripts).
    func script(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorPointer)
            throw SQLiteError(message: message)
        }
    }

    /// Runs one statement that returns no rows.
    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError(message: lastError)
        }
    }

    /// Runs one query and calls `row` for each result.
    func query(_ sql: String, _ values: [Value] = [], row: (Row) -> Void) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                row(Row(statement: statement))
            } else if result == SQLITE_DONE {
                return
            } else {
                throw SQLiteError(message: lastError)
            }
        }
    }

    /// All-or-nothing: if `body` throws, everything it did is rolled back.
    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    /// Schema version number kept inside the database file.
    var userVersion: Int {
        get {
            var version = 0
            try? query("PRAGMA user_version") { version = $0.int(0) }
            return version
        }
        set { try? run("PRAGMA user_version = \(newValue)") }
    }

    // MARK: - Internals

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError(message: lastError)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, transient)
            case .int(let i): sqlite3_bind_int64(statement, index, i)
            case .real(let d): sqlite3_bind_double(statement, index, d)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}
