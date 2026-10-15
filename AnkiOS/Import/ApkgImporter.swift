import Foundation
import SQLite3
import UniformTypeIdentifiers

extension UTType {
    static let ankiApkg = UTType(filenameExtension: "apkg") ?? .archive
    static let ankiColpkg = UTType(filenameExtension: "colpkg") ?? .archive
}

enum ImportError: Error, LocalizedError {
    case invalidPackage
    case missingCollection
    case stubCollection
    case unzipFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Invalid Anki package"
        case .missingCollection: return "No collection database found in package"
        case .stubCollection: return "Package requires a newer Anki format that could not be read"
        case .unzipFailed(let s): return "Unzip failed: \(s)"
        case .decodeFailed(let s): return s
        }
    }
}

@MainActor
final class ApkgImporter {
    private let store: CollectionStore

    init(store: CollectionStore) {
        self.store = store
    }

    @discardableResult
    func importPackage(at url: URL) async throws -> String {
        let isColpkg = url.pathExtension.lowercased() == "colpkg"
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("apkg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        try ZipArchive.unzip(url, to: temp)

        let collectionURL = try locateCollection(in: temp)
        let mediaMap = try loadMediaMap(in: temp)
        try store.mediaStore.copyImportedMedia(from: temp, mapping: mediaMap)
        try mergeCollection(from: collectionURL)
        try store.reloadMeta()
        try store.refreshCounts()
        store.notifyDeckContentAdded()
        if isColpkg {
            return "Colpkg mesclado na coleção local (baralhos, notas e mídia)."
        }
        return "Pacote .apkg importado na coleção."
    }

    private func locateCollection(in folder: URL) throws -> URL {
        let fm = FileManager.default
        let anki21b = folder.appendingPathComponent("collection.anki21b")
        let anki21 = folder.appendingPathComponent("collection.anki21")
        let anki2 = folder.appendingPathComponent("collection.anki2")

        if fm.fileExists(atPath: anki21b.path) {
            let decoded = try decodeAnki21b(anki21b, into: folder)
            if !(try isStubCollection(decoded)) { return decoded }
        }
        if fm.fileExists(atPath: anki21.path), !(try isStubCollection(anki21)) {
            return anki21
        }
        if fm.fileExists(atPath: anki2.path), !(try isStubCollection(anki2)) {
            return anki2
        }
        if fm.fileExists(atPath: anki21.path) { return anki21 }
        throw ImportError.missingCollection
    }

    /// collection.anki21b is a zstd-compressed SQLite database.
    private func decodeAnki21b(_ url: URL, into folder: URL) throws -> URL {
        let compressed = try Data(contentsOf: url)
        let plain = try Zstd.decompress(compressed)
        let out = folder.appendingPathComponent("collection.anki21b.decoded.anki21")
        try plain.write(to: out)
        return out
    }

    private func isStubCollection(_ url: URL) throws -> Bool {
        let db = try SQLiteDatabase(path: url.path)
        let count = try db.scalarInt("SELECT COUNT(*) FROM notes")
        if count == 1, let sfld = try db.scalarText("SELECT sfld FROM notes LIMIT 1") {
            return sfld.localizedCaseInsensitiveContains("Please update to the latest Anki")
                || sfld.localizedCaseInsensitiveContains("newer version of Anki")
        }
        return false
    }

    private func loadMediaMap(in folder: URL) throws -> [String: String] {
        let mediaURL = folder.appendingPathComponent("media")
        guard FileManager.default.fileExists(atPath: mediaURL.path) else { return [:] }
        let data = try Data(contentsOf: mediaURL)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return obj
        }
        return [:]
    }

    private func mergeCollection(from url: URL) throws {
        let src = try SQLiteDatabase(path: url.path)
        let modelsJSON = try src.scalarText("SELECT models FROM col") ?? "{}"
        let decksJSON = try src.scalarText("SELECT decks FROM col") ?? "{}"
        let dconfJSON = try src.scalarText("SELECT dconf FROM col") ?? "{}"
        let tagsJSON = try src.scalarText("SELECT tags FROM col") ?? "{}"
        let confJSON = try src.scalarText("SELECT conf FROM col") ?? "{}"

        if modelsJSON.count > 2 {
            try mergeSchema11(src: src, modelsJSON: modelsJSON, decksJSON: decksJSON, dconfJSON: dconfJSON, tagsJSON: tagsJSON, confJSON: confJSON)
        } else {
            try mergeSchema18(src: src)
        }
    }

    private func mergeSchema11(src: SQLiteDatabase, modelsJSON: String, decksJSON: String, dconfJSON: String, tagsJSON: String, confJSON: String) throws {
        let dest = store.db!

        let destDecksJSON = try dest.scalarText("SELECT decks FROM col") ?? "{}"
        let destModelsJSON = try dest.scalarText("SELECT models FROM col") ?? "{}"
        let destDconfJSON = try dest.scalarText("SELECT dconf FROM col") ?? "{}"
        let destTagsJSON = try dest.scalarText("SELECT tags FROM col") ?? "{}"

        try dest.run("UPDATE col SET decks=?, models=?, dconf=?, tags=?", bind: { stmt in
            try SQLiteDatabase.bindText(stmt, 1, try self.mergeJSONObjects(destDecksJSON, decksJSON))
            try SQLiteDatabase.bindText(stmt, 2, try self.mergeJSONObjects(destModelsJSON, modelsJSON))
            try SQLiteDatabase.bindText(stmt, 3, try self.mergeJSONObjects(destDconfJSON, dconfJSON))
            try SQLiteDatabase.bindText(stmt, 4, try self.mergeJSONObjects(destTagsJSON, tagsJSON))
        })

        if let importedConf = try JSONSerialization.jsonObject(with: Data(confJSON.utf8)) as? [String: Any],
           var localConf = try JSONSerialization.jsonObject(with: Data((try dest.scalarText("SELECT conf FROM col") ?? "{}").utf8)) as? [String: Any] {
            for (k, v) in importedConf where localConf[k] == nil {
                localConf[k] = v
            }
            try store.saveConf(localConf)
        }

        try copyNotesAndCards(from: src, to: dest)
        try copyRevlog(from: src, to: dest)
        try store.touchCol()
    }

    private func mergeSchema18(src: SQLiteDatabase) throws {
        let dest = store.db!
        var hasNotetypes = false
        try? src.query("SELECT name FROM sqlite_master WHERE type='table' AND name='notetypes'") { _ in
            hasNotetypes = true
        }
        if hasNotetypes {
            var models: [String: Any] = [:]
            try src.query("SELECT id, name, mtime_secs FROM notetypes") { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                let name = SQLiteDatabase.text(stmt, 1)
                let now = sqlite3_column_int64(stmt, 2)
                var basic = CollectionSchema.makeBasicNotetype(id: id, now: now)
                basic["name"] = name
                models[String(id)] = basic
            }
            let modelsJSON = CollectionSchema.encodeJSON(models)
            let destModels = try dest.scalarText("SELECT models FROM col") ?? "{}"
            try dest.run("UPDATE col SET models = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, try self.mergeJSONObjects(destModels, modelsJSON))
            })

            var decks: [String: Any] = [:]
            try src.query("SELECT id, name, mtime_secs FROM decks") { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                let name = SQLiteDatabase.text(stmt, 1)
                let mod = sqlite3_column_int64(stmt, 2)
                decks[String(id)] = [
                    "id": id, "name": name, "mod": mod, "usn": -1,
                    "collapsed": false, "browserCollapsed": false, "desc": "",
                    "dyn": 0, "conf": 1, "extendNew": 0, "extendRev": 0,
                    "newToday": [0, 0], "revToday": [0, 0], "lrnToday": [0, 0], "timeToday": [0, 0]
                ]
            }
            let decksJSON = CollectionSchema.encodeJSON(decks)
            let destDecks = try dest.scalarText("SELECT decks FROM col") ?? "{}"
            try dest.run("UPDATE col SET decks = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, try self.mergeJSONObjects(destDecks, decksJSON))
            })
        }
        try copyNotesAndCards(from: src, to: dest)
        try copyRevlog(from: src, to: dest)
        try store.touchCol()
    }

    /// Merge notes/cards like Anki desktop: match existing notes by `guid`, cards by `(nid, ord)`.
    private func copyNotesAndCards(from src: SQLiteDatabase, to dest: SQLiteDatabase) throws {
        var nidMap: [Int64: Int64] = [:]

        try src.query("SELECT id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data FROM notes") { stmt in
            let srcID = sqlite3_column_int64(stmt, 0)
            let guid = SQLiteDatabase.text(stmt, 1)
            let mid = sqlite3_column_int64(stmt, 2)
            let mod = sqlite3_column_int64(stmt, 3)
            let usn = Int(sqlite3_column_int(stmt, 4))
            let tags = SQLiteDatabase.text(stmt, 5)
            let flds = SQLiteDatabase.text(stmt, 6)
            let sfld = SQLiteDatabase.text(stmt, 7)
            let csum = sqlite3_column_int64(stmt, 8)
            let flags = Int(sqlite3_column_int(stmt, 9))
            let data = SQLiteDatabase.text(stmt, 10)

            if let existingID = try noteID(forGUID: guid, in: dest) {
                try dest.run("""
                    UPDATE notes SET mid=?, mod=?, usn=?, tags=?, flds=?, sfld=?, csum=? WHERE id=?
                """) { b in
                    SQLiteDatabase.bindInt64(b, 1, mid)
                    SQLiteDatabase.bindInt64(b, 2, mod)
                    SQLiteDatabase.bindInt(b, 3, usn)
                    try SQLiteDatabase.bindText(b, 4, tags)
                    try SQLiteDatabase.bindText(b, 5, flds)
                    try SQLiteDatabase.bindText(b, 6, sfld)
                    SQLiteDatabase.bindInt64(b, 7, csum)
                    SQLiteDatabase.bindInt64(b, 8, existingID)
                }
                nidMap[srcID] = existingID
            } else {
                var destID = srcID
                if try rowExists(in: dest, table: "notes", id: destID) {
                    destID = try allocateRowID(in: dest, table: "notes")
                }
                try dest.run("""
                    INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { b in
                    SQLiteDatabase.bindInt64(b, 1, destID)
                    try SQLiteDatabase.bindText(b, 2, guid)
                    SQLiteDatabase.bindInt64(b, 3, mid)
                    SQLiteDatabase.bindInt64(b, 4, mod)
                    SQLiteDatabase.bindInt(b, 5, usn)
                    try SQLiteDatabase.bindText(b, 6, tags)
                    try SQLiteDatabase.bindText(b, 7, flds)
                    try SQLiteDatabase.bindText(b, 8, sfld)
                    SQLiteDatabase.bindInt64(b, 9, csum)
                    SQLiteDatabase.bindInt(b, 10, flags)
                    try SQLiteDatabase.bindText(b, 11, data)
                }
                nidMap[srcID] = destID
            }
        }

        try src.query("""
            SELECT id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data
            FROM cards
        """) { stmt in
            let srcCID = sqlite3_column_int64(stmt, 0)
            let srcNID = sqlite3_column_int64(stmt, 1)
            let did = sqlite3_column_int64(stmt, 2)
            let ord = Int(sqlite3_column_int(stmt, 3))
            let mod = sqlite3_column_int64(stmt, 4)
            let usn = Int(sqlite3_column_int(stmt, 5))
            let type = Int(sqlite3_column_int(stmt, 6))
            let queue = Int(sqlite3_column_int(stmt, 7))
            let due = Int(sqlite3_column_int(stmt, 8))
            let ivl = Int(sqlite3_column_int(stmt, 9))
            let factor = Int(sqlite3_column_int(stmt, 10))
            let reps = Int(sqlite3_column_int(stmt, 11))
            let lapses = Int(sqlite3_column_int(stmt, 12))
            let left = Int(sqlite3_column_int(stmt, 13))
            let odue = Int(sqlite3_column_int(stmt, 14))
            let odid = sqlite3_column_int64(stmt, 15)
            let flags = Int(sqlite3_column_int(stmt, 16))
            let data = SQLiteDatabase.text(stmt, 17)

            let destNID = nidMap[srcNID] ?? srcNID

            if let existingCID = try cardID(nid: destNID, ord: ord, in: dest) {
                try dest.run("""
                    UPDATE cards SET nid=?, did=?, mod=?, usn=?, flags=?, data=? WHERE id=?
                """) { b in
                    SQLiteDatabase.bindInt64(b, 1, destNID)
                    SQLiteDatabase.bindInt64(b, 2, did)
                    SQLiteDatabase.bindInt64(b, 3, mod)
                    SQLiteDatabase.bindInt(b, 4, usn)
                    SQLiteDatabase.bindInt(b, 5, flags)
                    try SQLiteDatabase.bindText(b, 6, data)
                    SQLiteDatabase.bindInt64(b, 7, existingCID)
                }
                _ = srcCID
            } else {
                var destCID = srcCID
                if try rowExists(in: dest, table: "cards", id: destCID) {
                    destCID = try allocateRowID(in: dest, table: "cards")
                }
                try dest.run("""
                    INSERT INTO cards
                    (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { b in
                    SQLiteDatabase.bindInt64(b, 1, destCID)
                    SQLiteDatabase.bindInt64(b, 2, destNID)
                    SQLiteDatabase.bindInt64(b, 3, did)
                    SQLiteDatabase.bindInt(b, 4, ord)
                    SQLiteDatabase.bindInt64(b, 5, mod)
                    SQLiteDatabase.bindInt(b, 6, usn)
                    SQLiteDatabase.bindInt(b, 7, type)
                    SQLiteDatabase.bindInt(b, 8, queue)
                    SQLiteDatabase.bindInt(b, 9, due)
                    SQLiteDatabase.bindInt(b, 10, ivl)
                    SQLiteDatabase.bindInt(b, 11, factor)
                    SQLiteDatabase.bindInt(b, 12, reps)
                    SQLiteDatabase.bindInt(b, 13, lapses)
                    SQLiteDatabase.bindInt(b, 14, left)
                    SQLiteDatabase.bindInt(b, 15, odue)
                    SQLiteDatabase.bindInt64(b, 16, odid)
                    SQLiteDatabase.bindInt(b, 17, flags)
                    try SQLiteDatabase.bindText(b, 18, data)
                }
            }
        }
    }

    private func noteID(forGUID guid: String, in db: SQLiteDatabase) throws -> Int64? {
        var id: Int64?
        try db.query("SELECT id FROM notes WHERE guid = ? LIMIT 1") { stmt in
            try SQLiteDatabase.bindText(stmt, 1, guid)
        } map: { stmt in
            id = sqlite3_column_int64(stmt, 0)
        }
        return id
    }

    private func cardID(nid: Int64, ord: Int, in db: SQLiteDatabase) throws -> Int64? {
        var id: Int64?
        try db.query("SELECT id FROM cards WHERE nid = ? AND ord = ? LIMIT 1") { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, nid)
            SQLiteDatabase.bindInt(stmt, 2, ord)
        } map: { stmt in
            id = sqlite3_column_int64(stmt, 0)
        }
        return id
    }

    private func rowExists(in db: SQLiteDatabase, table: String, id: Int64) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM \(table) WHERE id = ?") { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, id)
        } > 0
    }

    private func allocateRowID(in db: SQLiteDatabase, table: String) throws -> Int64 {
        var id = Int64(Date().timeIntervalSince1970 * 1000)
        while try rowExists(in: db, table: table, id: id) {
            id += 1
        }
        return id
    }

    private func copyRevlog(from src: SQLiteDatabase, to dest: SQLiteDatabase) throws {
        try? src.query("SELECT id, cid, usn, ease, ivl, lastIvl, factor, time, type FROM revlog") { stmt in
            try? dest.run("""
                INSERT OR IGNORE INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { b in
                SQLiteDatabase.bindInt64(b, 1, sqlite3_column_int64(stmt, 0))
                SQLiteDatabase.bindInt64(b, 2, sqlite3_column_int64(stmt, 1))
                SQLiteDatabase.bindInt(b, 3, Int(sqlite3_column_int(stmt, 2)))
                SQLiteDatabase.bindInt(b, 4, Int(sqlite3_column_int(stmt, 3)))
                SQLiteDatabase.bindInt(b, 5, Int(sqlite3_column_int(stmt, 4)))
                SQLiteDatabase.bindInt(b, 6, Int(sqlite3_column_int(stmt, 5)))
                SQLiteDatabase.bindInt(b, 7, Int(sqlite3_column_int(stmt, 6)))
                SQLiteDatabase.bindInt(b, 8, Int(sqlite3_column_int(stmt, 7)))
                SQLiteDatabase.bindInt(b, 9, Int(sqlite3_column_int(stmt, 8)))
            }
        }
    }

    private func mergeJSONObjects(_ a: String, _ b: String) throws -> String {
        let ao = (try JSONSerialization.jsonObject(with: Data(a.utf8)) as? [String: Any]) ?? [:]
        let bo = (try JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String: Any]) ?? [:]
        var merged = ao
        for (k, v) in bo { merged[k] = v }
        return CollectionSchema.encodeJSON(merged)
    }
}
