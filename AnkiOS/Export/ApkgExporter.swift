import Foundation
import SQLite3

@MainActor
final class ApkgExporter {
    private let store: CollectionStore

    init(store: CollectionStore) {
        self.store = store
    }

    /// Export entire collection or a single deck tree to .apkg
    func export(deckID: Int64?, to destination: URL) throws {
        try export(deckID: deckID, cardIDs: nil, to: destination)
    }

    /// Export selected cards (and their notes) to .apkg — Anki browser “export selected”.
    func export(cardIDs: [Int64], to destination: URL) throws {
        try export(deckID: nil, cardIDs: cardIDs, to: destination)
    }

    private func export(deckID: Int64?, cardIDs: [Int64]?, to destination: URL) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let exportDBPath = temp.appendingPathComponent("collection.anki21")
        try fm.copyItem(at: store.collectionPath, to: exportDBPath)

        if let cardIDs, !cardIDs.isEmpty {
            try filterDatabase(at: exportDBPath, cardIDs: cardIDs)
        } else if let deckID {
            try filterDatabase(at: exportDBPath, deckID: deckID)
        }

        // media map
        let mediaDir = store.mediaRoot
        var mediaMap: [String: String] = [:]
        var index = 0
        let usedMedia: Set<String>?
        if let cardIDs, !cardIDs.isEmpty {
            usedMedia = try mediaUsed(byCards: cardIDs)
        } else if let deckID {
            usedMedia = try mediaUsed(byDeck: deckID)
        } else {
            usedMedia = nil
        }
        if let files = try? fm.contentsOfDirectory(atPath: mediaDir.path) {
            for file in files.sorted() {
                let src = mediaDir.appendingPathComponent(file)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                if let usedMedia, !usedMedia.contains(file) { continue }
                let name = String(index)
                try fm.copyItem(at: src, to: temp.appendingPathComponent(name))
                mediaMap[name] = file
                index += 1
            }
        }
        let mediaJSON = try JSONSerialization.data(withJSONObject: mediaMap)
        try mediaJSON.write(to: temp.appendingPathComponent("media"))
        try Data([0x01, 0x00]).write(to: temp.appendingPathComponent("meta")) // schema marker-ish

        // Also write collection.anki2 copy for compatibility
        try fm.copyItem(at: exportDBPath, to: temp.appendingPathComponent("collection.anki2"))

        try zipFolder(temp, to: destination)
    }

    private func filterDatabase(at url: URL, deckID: Int64) throws {
        let ids = store.deckTreeIDs(including: deckID)
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        try filterDatabase(at: url, keepCardsSQL: "did IN (\(ph))", bind: { stmt in
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        }, keepDeckIDs: Set(ids))
    }

    private func filterDatabase(at url: URL, cardIDs: [Int64]) throws {
        let ph = cardIDs.map { _ in "?" }.joined(separator: ",")
        var deckIDs = Set<Int64>()
        try store.db.query("SELECT DISTINCT did FROM cards WHERE id IN (\(ph))", bind: { stmt in
            for (i, id) in cardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        }) { stmt in
            deckIDs.insert(sqlite3_column_int64(stmt, 0))
        }
        try filterDatabase(at: url, keepCardsSQL: "id IN (\(ph))", bind: { stmt in
            for (i, id) in cardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        }, keepDeckIDs: deckIDs)
    }

    private func filterDatabase(
        at url: URL,
        keepCardsSQL: String,
        bind: @escaping (OpaquePointer) throws -> Void,
        keepDeckIDs: Set<Int64>
    ) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.run("DELETE FROM cards WHERE NOT (\(keepCardsSQL))", bind: bind)
        try db.run("DELETE FROM notes WHERE id NOT IN (SELECT nid FROM cards)")
        try db.run("DELETE FROM revlog WHERE cid NOT IN (SELECT id FROM cards)")

        if let decksJSON = try db.scalarText("SELECT decks FROM col"),
           var decks = try JSONSerialization.jsonObject(with: Data(decksJSON.utf8)) as? [String: Any] {
            let keep = Set(keepDeckIDs.map(String.init))
            decks = decks.filter { keep.contains($0.key) }
            try db.run("UPDATE col SET decks = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(decks))
            })
        }
    }

    private func mediaUsed(byDeck deckID: Int64) throws -> Set<String> {
        let ids = store.deckTreeIDs(including: deckID)
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        var fldsAll = ""
        try store.db.query("""
            SELECT n.flds FROM notes n JOIN cards c ON c.nid = n.id WHERE c.did IN (\(ph))
        """) { stmt in
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        } map: { stmt in
            fldsAll += SQLiteDatabase.text(stmt, 0) + " "
        }
        return Set(MediaStore.soundFiles(in: fldsAll))
    }

    private func mediaUsed(byCards cardIDs: [Int64]) throws -> Set<String> {
        guard !cardIDs.isEmpty else { return [] }
        let ph = cardIDs.map { _ in "?" }.joined(separator: ",")
        var fldsAll = ""
        try store.db.query("""
            SELECT n.flds FROM notes n JOIN cards c ON c.nid = n.id WHERE c.id IN (\(ph))
        """) { stmt in
            for (i, id) in cardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        } map: { stmt in
            fldsAll += SQLiteDatabase.text(stmt, 0) + " "
        }
        return Set(MediaStore.soundFiles(in: fldsAll))
    }

    private func zipFolder(_ folder: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try ZipWriter.createStoredZip(of: folder, to: destination)
    }
}

enum ZipWriter {
    static func createStoredZip(of folder: URL, to destination: URL) throws {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])!
        var entries: [(name: String, data: Data)] = []
        for case let fileURL as URL in enumerator {
            let rel = fileURL.path.replacingOccurrences(of: folder.path + "/", with: "")
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            if isDir.boolValue { continue }
            entries.append((rel, try Data(contentsOf: fileURL)))
        }

        var data = Data()
        var central = Data()
        var offset: UInt32 = 0
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let localHeaderOffset = offset
            var local = Data()
            local.append(contentsOf: UInt32(0x04034b50).leBytes)
            local.append(contentsOf: UInt16(20).leBytes) // version
            local.append(contentsOf: UInt16(0).leBytes) // flags
            local.append(contentsOf: UInt16(0).leBytes) // method store
            local.append(contentsOf: UInt16(0).leBytes) // time
            local.append(contentsOf: UInt16(0).leBytes) // date
            local.append(contentsOf: crc32(entry.data).leBytes)
            local.append(contentsOf: UInt32(entry.data.count).leBytes)
            local.append(contentsOf: UInt32(entry.data.count).leBytes)
            local.append(contentsOf: UInt16(nameData.count).leBytes)
            local.append(contentsOf: UInt16(0).leBytes)
            local.append(nameData)
            local.append(entry.data)
            data.append(local)
            offset += UInt32(local.count)

            var cen = Data()
            cen.append(contentsOf: UInt32(0x02014b50).leBytes)
            cen.append(contentsOf: UInt16(20).leBytes)
            cen.append(contentsOf: UInt16(20).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: crc32(entry.data).leBytes)
            cen.append(contentsOf: UInt32(entry.data.count).leBytes)
            cen.append(contentsOf: UInt32(entry.data.count).leBytes)
            cen.append(contentsOf: UInt16(nameData.count).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt32(0).leBytes)
            cen.append(contentsOf: localHeaderOffset.leBytes)
            cen.append(nameData)
            central.append(cen)
        }
        let centralOffset = UInt32(data.count)
        data.append(central)
        var end = Data()
        end.append(contentsOf: UInt32(0x06054b50).leBytes)
        end.append(contentsOf: UInt16(0).leBytes)
        end.append(contentsOf: UInt16(0).leBytes)
        end.append(contentsOf: UInt16(entries.count).leBytes)
        end.append(contentsOf: UInt16(entries.count).leBytes)
        end.append(contentsOf: UInt32(central.count).leBytes)
        end.append(contentsOf: centralOffset.leBytes)
        end.append(contentsOf: UInt16(0).leBytes)
        data.append(end)
        try data.write(to: destination)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xedb88320
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
    }
}

private extension UInt16 {
    var leBytes: [UInt8] { [UInt8(self & 0xff), UInt8((self >> 8) & 0xff)] }
}
private extension UInt32 {
    var leBytes: [UInt8] {
        [UInt8(self & 0xff), UInt8((self >> 8) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 24) & 0xff)]
    }
}
