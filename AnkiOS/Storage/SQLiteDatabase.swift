import Foundation
import SQLite3

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case bind(String)
    case exec(String)

    var errorDescription: String? {
        switch self {
        case .open(let s), .prepare(let s), .step(let s), .bind(let s), .exec(let s): return s
        }
    }
}

final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA foreign_keys = OFF;")
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA busy_timeout = 5000;")
    }

    deinit {
        sqlite3_close(db)
    }

    func closeConnection() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError.exec(message)
        }
    }

    @discardableResult
    func run(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        if let bind {
            try bind(stmt!)
        }
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil, map: (OpaquePointer) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        if let bind {
            try bind(stmt!)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            try map(stmt!)
        }
    }

    func scalarInt(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil) throws -> Int {
        var result = 0
        try query(sql, bind: bind) { stmt in
            result = Int(sqlite3_column_int(stmt, 0))
        }
        return result
    }

    func scalarInt64(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil) throws -> Int64 {
        var result: Int64 = 0
        try query(sql, bind: bind) { stmt in
            result = sqlite3_column_int64(stmt, 0)
        }
        return result
    }

    func scalarText(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil) throws -> String? {
        var result: String?
        try query(sql, bind: bind) { stmt in
            if let c = sqlite3_column_text(stmt, 0) {
                result = String(cString: c)
            }
        }
        return result
    }

    static func text(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    static func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) throws {
        if sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) != SQLITE_OK {
            throw SQLiteError.bind("text \(idx)")
        }
    }

    static func bindInt(_ stmt: OpaquePointer, _ idx: Int32, _ value: Int) {
        sqlite3_bind_int(stmt, idx, Int32(value))
    }

    static func bindInt64(_ stmt: OpaquePointer, _ idx: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, idx, value)
    }
}
