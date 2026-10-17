import Foundation
import SQLite3

private let sqliteFNVHashFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard let context, let arguments else { return }
    var values: [Int64] = []
    values.reserveCapacity(Int(argumentCount))
    for index in 0..<Int(argumentCount) {
        values.append(sqlite3_value_int64(arguments[index]))
    }
    sqlite3_result_int64(context, SQLiteDatabase.fnvHash(values))
}

private let sqliteFoldSearchTextFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard let context, argumentCount == 1, let arguments,
          let value = sqlite3_value_text(arguments[0]) else {
        if let context { sqlite3_result_null(context) }
        return
    }
    let text = String(cString: value)
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    text.withCString {
        sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

private let sqliteFSRSStabilityFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard let context, argumentCount == 1, let arguments,
          let value = sqlite3_value_text(arguments[0]) else {
        if let context { sqlite3_result_null(context) }
        return
    }
    guard let memory = FSRSCardData.memory(in: String(cString: value)) else {
        sqlite3_result_null(context)
        return
    }
    sqlite3_result_double(context, Double(memory.stability))
}

private let sqliteFSRSDifficultyFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard let context, argumentCount == 1, let arguments,
          let value = sqlite3_value_text(arguments[0]) else {
        if let context { sqlite3_result_null(context) }
        return
    }
    guard let memory = FSRSCardData.memory(in: String(cString: value)) else {
        sqlite3_result_null(context)
        return
    }
    sqlite3_result_double(context, Double(memory.difficulty))
}

private let sqliteFSRSRetrievabilityFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard let context, argumentCount == 5, let arguments,
          let value = sqlite3_value_text(arguments[0]) else {
        if let context { sqlite3_result_null(context) }
        return
    }
    let raw = String(cString: value)
    guard let memory = FSRSCardData.memory(in: raw) else {
        sqlite3_result_null(context)
        return
    }
    let due = Int(sqlite3_value_int64(arguments[1]))
    let interval = Int(sqlite3_value_int64(arguments[2]))
    let today = UInt32(truncatingIfNeeded: sqlite3_value_int64(arguments[3]))
    let now = UInt32(truncatingIfNeeded: sqlite3_value_int64(arguments[4]))
    let elapsed: Float
    if let lastReview = FSRSCardData.lastReview(in: raw) {
        let reviewedAt = UInt32(truncatingIfNeeded: lastReview)
        elapsed = Float(now >= reviewedAt ? now - reviewedAt : 0) / 86_400
    } else if due > 365_000 {
        let reviewTime = UInt32(truncatingIfNeeded: due) &- UInt32(truncatingIfNeeded: interval)
        elapsed = Float(now >= reviewTime ? now - reviewTime : 0) / 86_400
    } else {
        let reviewDay = UInt32(truncatingIfNeeded: due) &- UInt32(truncatingIfNeeded: interval)
        elapsed = Float(today >= reviewDay ? today - reviewDay : 0)
    }
    let retrievability = FSRS6.retrievability(
        daysElapsed: elapsed,
        stability: memory.stability,
        decay: FSRSCardData.decay(in: raw) ?? FSRS6.defaultDecay
    )
    sqlite3_result_double(context, Double(retrievability))
}

private func sqliteText(_ value: OpaquePointer?) -> String? {
    guard let value, sqlite3_value_type(value) == SQLITE_TEXT, let text = sqlite3_value_text(value) else { return nil }
    return String(cString: text)
}

private func sqliteInteger(_ value: OpaquePointer?) -> Int64? {
    guard let value, sqlite3_value_type(value) == SQLITE_INTEGER else { return nil }
    return sqlite3_value_int64(value)
}

/// rslib `extract_fsrs_variable(data, key)`.
private let sqliteExtractFSRSVariableFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard let context else { return }
    guard argumentCount == 2, let arguments,
          let data = sqliteText(arguments[0]), !data.isEmpty,
          let key = sqliteText(arguments[1]) else {
        sqlite3_result_null(context)
        return
    }
    let value: Float?
    switch key {
    case "s": value = FSRSCardData.memory(in: data)?.stability
    case "d": value = FSRSCardData.memory(in: data)?.difficulty
    case "dr": value = FSRSCardData.desiredRetention(in: data)
    default: value = nil
    }
    if let value { sqlite3_result_double(context, Double(value)) } else { sqlite3_result_null(context) }
}

/// rslib `extract_fsrs_retrievability(data, due, ivl, today, next_day_at, now)`.
private let sqliteExtractFSRSRetrievabilityFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard let context else { return }
    guard argumentCount == 6, let arguments,
          let data = sqliteText(arguments[0]), !data.isEmpty,
          let due = sqliteInteger(arguments[1]),
          let now = sqliteInteger(arguments[5]) else {
        sqlite3_result_null(context)
        return
    }
    let now32 = UInt32(truncatingIfNeeded: now)
    let secondsElapsed: UInt32
    if let lastReview = FSRSCardData.lastReview(in: data) {
        let review32 = UInt32(truncatingIfNeeded: lastReview)
        secondsElapsed = now32 >= review32 ? now32 - review32 : 0
    } else if due > 365_000 {
        guard let ivl = sqliteInteger(arguments[2]) else { sqlite3_result_null(context); return }
        let due32 = UInt32(truncatingIfNeeded: due), ivl32 = UInt32(truncatingIfNeeded: ivl)
        let reviewed = due32 >= ivl32 ? due32 - ivl32 : 0
        secondsElapsed = now32 >= reviewed ? now32 - reviewed : 0
    } else {
        guard let ivl = sqliteInteger(arguments[2]), let today = sqliteInteger(arguments[3]) else {
            sqlite3_result_null(context)
            return
        }
        let due32 = UInt32(truncatingIfNeeded: due), ivl32 = UInt32(truncatingIfNeeded: ivl)
        let reviewDay = due32 >= ivl32 ? due32 - ivl32 : 0
        let today32 = UInt32(truncatingIfNeeded: today)
        secondsElapsed = (today32 >= reviewDay ? today32 - reviewDay : 0) &* 86_400
    }
    guard let memory = FSRSCardData.memory(in: data) else {
        sqlite3_result_null(context)
        return
    }
    let decay = FSRSCardData.decay(in: data) ?? FSRS6.fsrs5Decay
    let value = FSRS6.retrievability(daysElapsed: Float(secondsElapsed) / 86_400, stability: memory.stability, decay: decay)
    sqlite3_result_double(context, Double(value))
}

/// rslib `extract_fsrs_relative_retrievability(data, due, ivl, today, next_day_at, now)`.
private let sqliteExtractFSRSRelativeRetrievabilityFunction: @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { context, argumentCount, arguments in
    guard let context else { return }
    guard argumentCount == 6, let arguments,
          let due = sqliteInteger(arguments[1]),
          let interval = sqliteInteger(arguments[2]),
          let now = sqliteInteger(arguments[5]) else {
        sqlite3_result_null(context)
        return
    }
    let now32 = UInt32(truncatingIfNeeded: now)
    let secsElapsed: UInt32
    if due > 365_000 {
        let due32 = UInt32(truncatingIfNeeded: due)
        secsElapsed = now32 >= due32 ? now32 - due32 : 0
    } else {
        guard let today = sqliteInteger(arguments[3]) else { sqlite3_result_null(context); return }
        let reviewDay = UInt32(truncatingIfNeeded: due &- interval)
        let today32 = UInt32(truncatingIfNeeded: today)
        secsElapsed = (today32 >= reviewDay ? today32 - reviewDay : 0) &* 86_400
    }
    if let data = sqliteText(arguments[0]), !data.isEmpty,
       let memory = FSRSCardData.memory(in: data),
       let desired = FSRSCardData.desiredRetention(in: data) {
        let desiredRetrievability = max(desired, 0.0001)
        let decay = FSRSCardData.decay(in: data) ?? FSRS6.fsrs5Decay
        let secondsElapsed: UInt32
        if let lastReview = FSRSCardData.lastReview(in: data) {
            let review32 = UInt32(truncatingIfNeeded: lastReview)
            secondsElapsed = now32 >= review32 ? now32 - review32 : 0
        } else {
            secondsElapsed = secsElapsed
        }
        let current = max(
            FSRS6.retrievability(daysElapsed: Float(secondsElapsed) / 86_400, stability: memory.stability, decay: decay),
            0.0001
        )
        let value = -(pow(current, -1 / decay) - 1) / (pow(desiredRetrievability, -1 / decay) - 1)
        sqlite3_result_double(context, Double(value))
        return
    }
    let daysElapsed = secsElapsed / 86_400
    let value = -(Float(daysElapsed) + 0.001) / max(Float(interval), 1)
    sqlite3_result_double(context, Double(value))
}

enum SQLiteHash {
    static func fnv(_ values: [Int64]) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for item in values {
            var value = UInt64(bitPattern: item)
            for _ in 0..<MemoryLayout<Int64>.size {
                hash ^= value & 0xff
                hash = hash &* 0x0000_0100_0000_01b3
                value >>= 8
            }
        }
        return Int64(bitPattern: hash)
    }
}

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
    static func fnvHash(_ values: [Int64]) -> Int64 {
        SQLiteHash.fnv(values)
    }

    private var db: OpaquePointer?
    private let lock = NSLock()

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
        }
        let collationResult = sqlite3_create_collation_v2(db, "unicase", SQLITE_UTF8, nil, sqliteUnicodeCaseInsensitiveCompare, nil)
        guard collationResult == SQLITE_OK else {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
        }
        let hashResult = sqlite3_create_function_v2(
            db,
            "fnvhash",
            -1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            sqliteFNVHashFunction,
            nil,
            nil,
            nil
        )
        guard hashResult == SQLITE_OK else {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
        }
        let foldSearchTextResult = sqlite3_create_function_v2(
            db,
            "fold_search_text",
            1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            sqliteFoldSearchTextFunction,
            nil,
            nil,
            nil
        )
        guard foldSearchTextResult == SQLITE_OK else {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
        }
        for (name, argumentCount, function) in [
            ("anki_fsrs_stability", Int32(1), sqliteFSRSStabilityFunction),
            ("anki_fsrs_difficulty", Int32(1), sqliteFSRSDifficultyFunction),
            ("anki_fsrs_retrievability", Int32(5), sqliteFSRSRetrievabilityFunction),
            ("extract_fsrs_variable", Int32(2), sqliteExtractFSRSVariableFunction),
            ("extract_fsrs_retrievability", Int32(6), sqliteExtractFSRSRetrievabilityFunction),
            ("extract_fsrs_relative_retrievability", Int32(6), sqliteExtractFSRSRelativeRetrievabilityFunction)
        ] {
            let result = sqlite3_create_function_v2(
                db,
                name,
                argumentCount,
                SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                nil,
                function,
                nil,
                nil,
                nil
            )
            guard result == SQLITE_OK else {
                throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
            }
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

    var isInTransaction: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }
        return sqlite3_get_autocommit(db) == 0
    }

    func backup(to destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let source = db else { throw SQLiteError.open("Database is closed") }
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let target else {
            let message = target.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open backup database"
            if let target { sqlite3_close(target) }
            throw SQLiteError.open(message)
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else {
            throw SQLiteError.exec(String(cString: sqlite3_errmsg(target)))
        }
        var result = sqlite3_backup_step(backup, -1)
        while result == SQLITE_BUSY || result == SQLITE_LOCKED {
            Thread.sleep(forTimeInterval: 0.05)
            result = sqlite3_backup_step(backup, -1)
        }
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw SQLiteError.exec(String(cString: sqlite3_errmsg(target)))
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

    /// Steps through rows until `body` returns false.
    func forEachRow(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil, _ body: (OpaquePointer) throws -> Bool) throws {
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
            guard try body(stmt!) else { break }
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

    static func blob(_ stmt: OpaquePointer, _ idx: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, idx))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, idx) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    static func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) throws {
        if sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) != SQLITE_OK {
            throw SQLiteError.bind("text \(idx)")
        }
    }

    static func bindBlob(_ stmt: OpaquePointer, _ idx: Int32, _ value: Data) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, idx, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        if result != SQLITE_OK { throw SQLiteError.bind("blob \(idx)") }
    }

    static func bindInt(_ stmt: OpaquePointer, _ idx: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, idx, Int64(value))
    }

    static func bindInt64(_ stmt: OpaquePointer, _ idx: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, idx, value)
    }
}

private let sqliteUnicodeCaseInsensitiveCompare: @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafeRawPointer?
) -> Int32 = { _, leftCount, leftBytes, rightCount, rightBytes in
    func value(_ bytes: UnsafeRawPointer?, _ count: Int32) -> String {
        guard count > 0, let bytes else { return "" }
        let buffer = UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: Int(count))
        return String(decoding: buffer, as: UTF8.self).lowercased()
    }

    let left = value(leftBytes, leftCount)
    let right = value(rightBytes, rightCount)
    if left < right { return -1 }
    if left > right { return 1 }
    return 0
}
