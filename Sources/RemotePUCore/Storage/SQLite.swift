import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper (system libsqlite3, no dependencies). Not thread-safe;
/// owned by the HistoryStore actor.
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(message: msg)
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000;")
    }

    deinit { sqlite3_close(db) }

    var lastError: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "\(lastError) in: \(sql)")
        }
        return Statement(stmt, db: self)
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    final class Statement {
        private let stmt: OpaquePointer
        private unowned let db: SQLiteDB

        init(_ stmt: OpaquePointer, db: SQLiteDB) {
            self.stmt = stmt
            self.db = db
        }

        deinit { sqlite3_finalize(stmt) }

        func reset() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        func bind(_ index: Int32, _ value: Double?) {
            if let value, value.isFinite { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
        }

        func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(stmt, index, value) }

        func bind(_ index: Int32, _ value: String) { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) }

        /// Returns true while a row is available.
        @discardableResult
        func step() throws -> Bool {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError(message: db.lastError)
            }
        }

        func double(_ col: Int32) -> Double? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
        }

        func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }

        func text(_ col: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: p)
        }
    }
}
