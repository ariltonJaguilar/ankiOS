import Foundation
import CryptoKit
import SQLite3

struct ApkgExportOptions {
    var includeScheduling: Bool
    var includeDeckPresets: Bool
    var includeMedia: Bool

    init(configuration: [String: Any]) {
        includeScheduling = configuration["apkgIncludeScheduling"] as? Bool ?? false
        includeDeckPresets = configuration["apkgIncludeDeckPresets"] as? Bool ?? false
        includeMedia = configuration["apkgIncludeMedia"] as? Bool ?? true
    }
}

@MainActor
final class ApkgExporter {
    private let store: CollectionStore

    init(store: CollectionStore) {
        self.store = store
    }

    /// Export entire collection or a single deck tree to .apkg
    func export(deckID: Int64?, to destination: URL, options: ApkgExportOptions? = nil) throws {
        try export(deckID: deckID, cardIDs: nil, to: destination, options: options)
    }

    func exportCollectionPackage(to destination: URL, options: ApkgExportOptions? = nil) throws {
        let options = options ?? ApkgExportOptions(configuration: store.conf)
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("colpkg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let collectionURL = temp.appendingPathComponent("collection.sqlite")
        try store.db.backup(to: collectionURL)
        try prepareModernPackageFiles(in: temp, collection: collectionURL, mediaDirectory: store.mediaRoot, usedMedia: nil, includeMedia: options.includeMedia)
        try zipFolder(temp, to: destination)
    }

    /// Export selected cards (and their notes) to .apkg — Anki browser “export selected”.
    func export(cardIDs: [Int64], to destination: URL, options: ApkgExportOptions? = nil) throws {
        try export(deckID: nil, cardIDs: cardIDs, to: destination, options: options)
    }

    private func export(deckID: Int64?, cardIDs: [Int64]?, to destination: URL, options: ApkgExportOptions?) throws {
        let options = options ?? ApkgExportOptions(configuration: store.conf)
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let exportDBPath = temp.appendingPathComponent("collection.sqlite")
        try store.db.backup(to: exportDBPath)

        if let cardIDs {
            try filterDatabase(at: exportDBPath, cardIDs: cardIDs)
        } else if let deckID {
            try filterDatabase(at: exportDBPath, deckID: deckID)
        } else {
            try filterDatabase(
                at: exportDBPath,
                keepNotesSQL: "1",
                bind: { _ in },
                keepNotesWithoutCards: true
            )
        }

        if !options.includeScheduling {
            try resetScheduling(at: exportDBPath, includeDeckPresets: options.includeDeckPresets)
        }
        try prunePackageMetadata(at: exportDBPath, includeDefaultDeck: options.includeScheduling)
        if !options.includeDeckPresets {
            try stripDeckPresets(at: exportDBPath)
        } else if !options.includeScheduling {
            try stripFSRSParameters(at: exportDBPath)
        }
        try clearPackageLocalState(at: exportDBPath)

        let usedMedia: Set<String>?
        if let cardIDs {
            usedMedia = try mediaUsed(byCards: cardIDs)
        } else if let deckID {
            usedMedia = try mediaUsed(byDeck: deckID)
        } else {
            usedMedia = try mediaUsedByCollection()
        }
        try prepareModernPackageFiles(in: temp, collection: exportDBPath, mediaDirectory: store.mediaRoot, usedMedia: usedMedia, includeMedia: options.includeMedia)
        try zipFolder(temp, to: destination)
    }

    private func prepareModernPackageFiles(
        in folder: URL,
        collection: URL,
        mediaDirectory: URL,
        usedMedia: Set<String>?,
        includeMedia: Bool
    ) throws {
        let fm = FileManager.default
        try convertToSchema18(at: collection)
        try Zstd.compressFile(collection, to: folder.appendingPathComponent("collection.anki21b"))
        try fm.removeItem(at: collection)
        try Data([0x08, 0x03]).write(to: folder.appendingPathComponent("meta"))
        try makeDummyCollection(at: folder.appendingPathComponent("collection.anki2"))

        var mediaManifest = Data()
        var mediaIndex = 0
        if includeMedia, let files = try? fm.contentsOfDirectory(atPath: mediaDirectory.path) {
            for filename in files.sorted() {
                let source = mediaDirectory.appendingPathComponent(filename)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                if let usedMedia, !usedMedia.contains(filename) { continue }
                let attributes = try fm.attributesOfItem(atPath: source.path)
                guard let rawSize = attributes[.size] as? NSNumber, rawSize.uint64Value <= UInt64(UInt32.max) else {
                    throw ImportError.decodeFailed("Um arquivo de mídia excede o limite do formato Anki.")
                }
                let archiveName = String(mediaIndex)
                let compressed = folder.appendingPathComponent(archiveName)
                try Zstd.compressFile(source, to: compressed)
                let digest = Data(Insecure.SHA1.hash(data: try Data(contentsOf: source)))
                mediaManifest.append(ProtoWriter.bytes(field: 1, value: ProtoWriter.message([
                    ProtoWriter.string(field: 1, value: filename),
                    ProtoWriter.uint(field: 2, value: UInt64(rawSize.uint32Value)),
                    ProtoWriter.bytes(field: 3, value: digest)
                ])))
                mediaIndex += 1
            }
        }
        try Zstd.compress(mediaManifest).write(to: folder.appendingPathComponent("media"))
    }

    private func convertToSchema18(at url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        guard try db.scalarInt("SELECT ver FROM col") == 11 else {
            throw ImportError.decodeFailed("A exportação moderna exige uma coleção de origem no esquema V11.")
        }
        let conf = try CollectionSchema.collectionConfig(from: db)
        let models = try jsonObject(db.scalarText("SELECT models FROM col") ?? "{}")
        let decks = try jsonObject(db.scalarText("SELECT decks FROM col") ?? "{}")
        let deckConfigs = try jsonObject(db.scalarText("SELECT dconf FROM col") ?? "{}")
        let tags = try jsonObject(db.scalarText("SELECT tags FROM col") ?? "{}")
        let now = Int64(Date().timeIntervalSince1970)

        try db.exec("""
            BEGIN IMMEDIATE;
            DROP TABLE IF EXISTS config;
            CREATE TABLE config (key TEXT NOT NULL PRIMARY KEY, usn INTEGER NOT NULL, mtime_secs INTEGER NOT NULL, val BLOB NOT NULL) WITHOUT ROWID;
            CREATE TABLE deck_config (id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL COLLATE unicase, mtime_secs INTEGER NOT NULL, usn INTEGER NOT NULL, config BLOB NOT NULL);
            CREATE TABLE tags (tag TEXT NOT NULL PRIMARY KEY COLLATE unicase, usn INTEGER NOT NULL, collapsed BOOLEAN NOT NULL, config BLOB NULL) WITHOUT ROWID;
            CREATE TABLE notetypes (id INTEGER NOT NULL PRIMARY KEY, name TEXT NOT NULL COLLATE unicase, mtime_secs INTEGER NOT NULL, usn INTEGER NOT NULL, config BLOB NOT NULL);
            CREATE TABLE fields (ntid INTEGER NOT NULL, ord INTEGER NOT NULL, name TEXT NOT NULL COLLATE unicase, config BLOB NOT NULL, PRIMARY KEY (ntid, ord)) WITHOUT ROWID;
            CREATE TABLE templates (ntid INTEGER NOT NULL, ord INTEGER NOT NULL, name TEXT NOT NULL COLLATE unicase, mtime_secs INTEGER NOT NULL, usn INTEGER NOT NULL, config BLOB NOT NULL, PRIMARY KEY (ntid, ord)) WITHOUT ROWID;
            CREATE TABLE decks (id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL COLLATE unicase, mtime_secs INTEGER NOT NULL, usn INTEGER NOT NULL, common BLOB NOT NULL, kind BLOB NOT NULL);
            CREATE TABLE graves_v18 (oid INTEGER NOT NULL, type INTEGER NOT NULL, usn INTEGER NOT NULL, PRIMARY KEY(oid, type)) WITHOUT ROWID;
            INSERT INTO graves_v18 (oid, type, usn) SELECT oid, type, MAX(usn) FROM graves GROUP BY oid, type;
            CREATE INDEX IF NOT EXISTS ix_notes_csum ON notes (csum);
            CREATE UNIQUE INDEX idx_fields_name_ntid ON fields (name, ntid);
            CREATE UNIQUE INDEX idx_templates_name_ntid ON templates (name, ntid);
            CREATE INDEX idx_templates_usn ON templates (usn);
            CREATE UNIQUE INDEX idx_notetypes_name ON notetypes (name);
            CREATE INDEX idx_notetypes_usn ON notetypes (usn);
            CREATE UNIQUE INDEX idx_decks_name ON decks (name);
            CREATE INDEX idx_notes_mid ON notes (mid);
            CREATE INDEX idx_cards_odid ON cards (odid) WHERE odid != 0;
            DROP TABLE graves;
            ALTER TABLE graves_v18 RENAME TO graves;
            CREATE INDEX idx_graves_pending ON graves (usn);
            """)

        for (key, value) in conf {
            let valueData = try jsonData(value)
            try db.run("INSERT INTO config (key, usn, mtime_secs, val) VALUES (?, -1, ?, ?)") { stmt in
                try SQLiteDatabase.bindText(stmt, 1, key)
                SQLiteDatabase.bindInt64(stmt, 2, now)
                try SQLiteDatabase.bindBlob(stmt, 3, valueData)
            }
        }

        for (key, value) in tags {
            let usn = (value as? NSNumber)?.intValue ?? -1
            try db.run("INSERT INTO tags (tag, usn, collapsed, config) VALUES (?, ?, 0, NULL)") { stmt in
                try SQLiteDatabase.bindText(stmt, 1, key)
                SQLiteDatabase.bindInt(stmt, 2, usn)
            }
        }

        for (key, value) in deckConfigs {
            guard let id = Int64(key), let object = value as? [String: Any] else { continue }
            let configData = try encodeDeckConfig(object)
            try db.run("INSERT INTO deck_config (id, name, mtime_secs, usn, config) VALUES (?, ?, ?, ?, ?)") { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, id)
                try SQLiteDatabase.bindText(stmt, 2, object["name"] as? String ?? "Default")
                SQLiteDatabase.bindInt64(stmt, 3, self.integer64(object["mod"], fallback: now))
                SQLiteDatabase.bindInt(stmt, 4, self.integer(object["usn"], fallback: -1))
                try SQLiteDatabase.bindBlob(stmt, 5, configData)
            }
        }

        for (key, value) in models {
            guard let id = Int64(key), let model = value as? [String: Any] else { continue }
            let notetypeConfig = try encodeNotetype(model)
            try db.run("INSERT INTO notetypes (id, name, mtime_secs, usn, config) VALUES (?, ?, ?, ?, ?)") { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, id)
                try SQLiteDatabase.bindText(stmt, 2, model["name"] as? String ?? "")
                SQLiteDatabase.bindInt64(stmt, 3, self.integer64(model["mod"], fallback: now))
                SQLiteDatabase.bindInt(stmt, 4, self.integer(model["usn"], fallback: -1))
                try SQLiteDatabase.bindBlob(stmt, 5, notetypeConfig)
            }
            let fields = model["flds"] as? [[String: Any]] ?? []
            for (index, field) in fields.enumerated() {
                let ord = integer(field["ord"], fallback: index)
                let fieldConfig = encodeField(field)
                try db.run("INSERT INTO fields (ntid, ord, name, config) VALUES (?, ?, ?, ?)") { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, id)
                    SQLiteDatabase.bindInt(stmt, 2, ord)
                    try SQLiteDatabase.bindText(stmt, 3, field["name"] as? String ?? "")
                    try SQLiteDatabase.bindBlob(stmt, 4, fieldConfig)
                }
            }
            let templates = model["tmpls"] as? [[String: Any]] ?? []
            for (index, template) in templates.enumerated() {
                let ord = integer(template["ord"], fallback: index)
                let templateConfig = encodeTemplate(template)
                try db.run("INSERT INTO templates (ntid, ord, name, mtime_secs, usn, config) VALUES (?, ?, ?, ?, ?, ?)") { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, id)
                    SQLiteDatabase.bindInt(stmt, 2, ord)
                    try SQLiteDatabase.bindText(stmt, 3, template["name"] as? String ?? "")
                    SQLiteDatabase.bindInt64(stmt, 4, self.integer64(template["mod"], fallback: self.integer64(model["mod"], fallback: now)))
                    SQLiteDatabase.bindInt(stmt, 5, self.integer(template["usn"], fallback: self.integer(model["usn"], fallback: -1)))
                    try SQLiteDatabase.bindBlob(stmt, 6, templateConfig)
                }
            }
        }

        for (key, value) in decks {
            guard let id = Int64(key), let deck = value as? [String: Any] else { continue }
            let common = encodeDeckCommon(deck)
            let kind = try encodeDeckKind(deck)
            let name = (deck["name"] as? String ?? "Default").replacingOccurrences(of: "::", with: "\u{1f}")
            try db.run("INSERT INTO decks (id, name, mtime_secs, usn, common, kind) VALUES (?, ?, ?, ?, ?, ?)") { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, id)
                try SQLiteDatabase.bindText(stmt, 2, name)
                SQLiteDatabase.bindInt64(stmt, 3, self.integer64(deck["mod"], fallback: now))
                SQLiteDatabase.bindInt(stmt, 4, self.integer(deck["usn"], fallback: -1))
                try SQLiteDatabase.bindBlob(stmt, 5, common)
                try SQLiteDatabase.bindBlob(stmt, 6, kind)
            }
        }

        try db.run("UPDATE col SET ver=18, conf='', models='{}', decks='{}', dconf='{}', tags='{}'")
        try db.exec("COMMIT;")
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; VACUUM;")
        db.closeConnection()
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    private func encodeDeckConfig(_ config: [String: Any]) throws -> Data {
        let new = config["new"] as? [String: Any] ?? [:]
        let review = config["rev"] as? [String: Any] ?? [:]
        let lapse = config["lapse"] as? [String: Any] ?? [:]
        var fields = [
            ProtoWriter.floats(field: 1, values: numbers(new["delays"])),
            ProtoWriter.floats(field: 2, values: numbers(lapse["delays"])),
            ProtoWriter.floats(field: 4, values: numbers(config["easyDayPercents"])),
            ProtoWriter.uint(field: 9, value: uint(new["perDay"], fallback: 20)),
            ProtoWriter.uint(field: 10, value: uint(review["perDay"], fallback: 200)),
            ProtoWriter.float(field: 11, value: Double(integer(new["initialFactor"], fallback: 2500)) / 1000),
            ProtoWriter.float(field: 12, value: number(review["ease4"], fallback: 1.3)),
            ProtoWriter.float(field: 13, value: number(review["hardFactor"], fallback: 1.2)),
            ProtoWriter.float(field: 14, value: number(lapse["mult"])),
            ProtoWriter.float(field: 15, value: number(review["ivlFct"], fallback: 1)),
            ProtoWriter.uint(field: 16, value: uint(review["maxIvl"], fallback: 36500)),
            ProtoWriter.uint(field: 17, value: uint(lapse["minInt"], fallback: 1)),
            ProtoWriter.uint(field: 18, value: uintAt(new["ints"], 0, fallback: 1)),
            ProtoWriter.uint(field: 19, value: uintAt(new["ints"], 1, fallback: 4)),
            ProtoWriter.uint(field: 20, value: integer(new["order"], fallback: 1) == 0 ? 1 : 0),
            ProtoWriter.uint(field: 21, value: uint(lapse["leechAction"])),
            ProtoWriter.uint(field: 22, value: uint(lapse["leechFails"], fallback: 8)),
            ProtoWriter.bool(field: 23, value: !(config["autoplay"] as? Bool ?? true)),
            ProtoWriter.uint(field: 24, value: uint(config["maxTaken"], fallback: 60)),
            ProtoWriter.bool(field: 25, value: integer(config["timer"]) != 0),
            ProtoWriter.bool(field: 26, value: !(config["replayq"] as? Bool ?? true)),
            ProtoWriter.bool(field: 27, value: new["bury"] as? Bool ?? false),
            ProtoWriter.bool(field: 28, value: review["bury"] as? Bool ?? false),
            ProtoWriter.bool(field: 29, value: config["buryInterdayLearning"] as? Bool ?? false),
            ProtoWriter.uint(field: 30, value: uint(config["newMix"])),
            ProtoWriter.uint(field: 31, value: uint(config["interdayLearningMix"])),
            ProtoWriter.uint(field: 32, value: uint(config["newSortOrder"])),
            ProtoWriter.uint(field: 33, value: modernReviewOrder(integer(config["reviewOrder"]))),
            ProtoWriter.uint(field: 34, value: modernGatherPriority(integer(config["newGatherPriority"]))),
            ProtoWriter.uint(field: 35, value: uint(config["newPerDayMinimum"])),
            ProtoWriter.uint(field: 36, value: uint(config["questionAction"])),
            ProtoWriter.float(field: 37, value: number(config["desiredRetention"], fallback: 0.9)),
            ProtoWriter.bool(field: 38, value: config["stopTimerOnAnswer"] as? Bool ?? false),
            ProtoWriter.float(field: 40, value: number(config["historicalRetention"], fallback: 0.9)),
            ProtoWriter.float(field: 41, value: number(config["secondsToShowQuestion"])),
            ProtoWriter.float(field: 42, value: number(config["secondsToShowAnswer"])),
            ProtoWriter.uint(field: 43, value: uint(config["answerAction"])),
            ProtoWriter.bool(field: 44, value: config["waitForAudio"] as? Bool ?? true)
        ]
        if let search = config["paramSearch"] as? String, !search.isEmpty { fields.append(ProtoWriter.string(field: 45, value: search)) }
        if let date = config["ignoreRevlogsBeforeDate"] as? String, !date.isEmpty { fields.append(ProtoWriter.string(field: 46, value: date)) }
        let fsrs4 = numbers(config["fsrsWeights"])
        let fsrs5 = numbers(config["fsrsParams5"])
        let fsrs6 = numbers(config["fsrsParams6"])
        if !fsrs4.isEmpty {
            let inferredField = fsrs4.count <= 17 ? 3 : fsrs4.count <= 19 ? 5 : 6
            let field = fsrs5.isEmpty && fsrs6.isEmpty ? inferredField : 3
            fields.append(ProtoWriter.floats(field: field, values: fsrs4))
        }
        if !fsrs5.isEmpty { fields.append(ProtoWriter.floats(field: 5, values: fsrs5)) }
        if !fsrs6.isEmpty { fields.append(ProtoWriter.floats(field: 6, values: fsrs6)) }
        appendProtoOther(
            from: config,
            excluding: ["id", "name", "mod", "usn", "maxTaken", "autoplay", "timer", "stopTimerOnAnswer", "replayq", "dyn", "newMix", "newPerDayMinimum", "interdayLearningMix", "newSortOrder", "reviewOrder", "newGatherPriority", "buryInterdayLearning", "fsrsWeights", "fsrsParams5", "fsrsParams6", "desiredRetention", "historicalRetention", "ignoreRevlogsBeforeDate", "paramSearch", "secondsToShowQuestion", "secondsToShowAnswer", "questionAction", "answerAction", "waitForAudio", "easyDayPercents"],
            to: &fields
        )
        return ProtoWriter.message(fields)
    }

    private func encodeNotetype(_ model: [String: Any]) throws -> Data {
        var fields = [
            ProtoWriter.uint(field: 1, value: uint(model["type"])),
            ProtoWriter.uint(field: 2, value: uint(model["sortf"])),
            ProtoWriter.string(field: 3, value: model["css"] as? String ?? AnkiNotetype.defaultCSS),
            ProtoWriter.string(field: 5, value: model["latexPre"] as? String ?? ""),
            ProtoWriter.string(field: 6, value: model["latexPost"] as? String ?? ""),
            ProtoWriter.bool(field: 7, value: model["latexsvg"] as? Bool ?? false)
        ]
        if let deckID = model["did"], !(deckID is NSNull) {
            fields.append(ProtoWriter.uint(field: 4, value: uint(deckID)))
        }
        for requirement in model["req"] as? [[Any]] ?? [] {
            guard requirement.count >= 3 else { continue }
            let kind: UInt64
            if let name = requirement[1] as? String {
                switch name {
                case "any": kind = 1
                case "all": kind = 2
                default: kind = 0
                }
            } else if let number = requirement[1] as? NSNumber {
                kind = UInt64(bitPattern: number.int64Value)
            } else {
                kind = 0
            }
            let req = ProtoWriter.message([
                ProtoWriter.uint(field: 1, value: uint(requirement[0])),
                ProtoWriter.uint(field: 2, value: kind),
                ProtoWriter.packedUInt(field: 3, values: (requirement[2] as? [Any] ?? []).map { uint($0) })
            ])
            fields.append(ProtoWriter.bytes(field: 8, value: req))
        }
        if let originalStockKind = model["originalStockKind"], !(originalStockKind is NSNull) {
            fields.append(ProtoWriter.uint(field: 9, value: uint(originalStockKind)))
        }
        if let originalID = model["originalId"], !(originalID is NSNull) {
            fields.append(ProtoWriter.uint(field: 10, value: UInt64(bitPattern: integer64(originalID))))
        }
        appendProtoOther(
            from: model,
            excluding: ["id", "name", "type", "mod", "usn", "sortf", "did", "tmpls", "flds", "css", "latexPre", "latexPost", "latexsvg", "req", "originalStockKind", "originalId"],
            to: &fields
        )
        return ProtoWriter.message(fields)
    }

    private func encodeField(_ field: [String: Any]) -> Data {
        var fields = [
            ProtoWriter.bool(field: 1, value: field["sticky"] as? Bool ?? false),
            ProtoWriter.bool(field: 2, value: field["rtl"] as? Bool ?? false),
            ProtoWriter.string(field: 3, value: field["font"] as? String ?? "Arial"),
            ProtoWriter.uint(field: 4, value: uint(field["size"], fallback: 20)),
            ProtoWriter.string(field: 5, value: field["description"] as? String ?? ""),
            ProtoWriter.bool(field: 6, value: field["plainText"] as? Bool ?? false),
            ProtoWriter.bool(field: 7, value: field["collapsed"] as? Bool ?? false),
            ProtoWriter.bool(field: 8, value: field["excludeFromSearch"] as? Bool ?? false),
            ProtoWriter.bool(field: 11, value: field["preventDeletion"] as? Bool ?? false)
        ]
        if let id = field["id"] { fields.append(ProtoWriter.uint(field: 9, value: uint(id))) }
        if let tag = field["tag"] { fields.append(ProtoWriter.uint(field: 10, value: uint(tag))) }
        appendProtoOther(
            from: field,
            excluding: ["name", "ord", "sticky", "rtl", "font", "size", "description", "plainText", "collapsed", "excludeFromSearch", "id", "tag", "preventDeletion"],
            to: &fields
        )
        return ProtoWriter.message(fields)
    }

    private func encodeTemplate(_ template: [String: Any]) -> Data {
        var configFields = [
            ProtoWriter.string(field: 1, value: template["qfmt"] as? String ?? ""),
            ProtoWriter.string(field: 2, value: template["afmt"] as? String ?? ""),
            ProtoWriter.string(field: 3, value: template["bqfmt"] as? String ?? ""),
            ProtoWriter.string(field: 4, value: template["bafmt"] as? String ?? ""),
            ProtoWriter.string(field: 6, value: template["bfont"] as? String ?? ""),
            ProtoWriter.uint(field: 7, value: uint(template["bsize"]))
        ]
        if let deckID = template["did"], !(deckID is NSNull) {
            configFields.append(ProtoWriter.uint(field: 5, value: uint(deckID)))
        }
        if let id = template["id"] { configFields.append(ProtoWriter.uint(field: 8, value: uint(id))) }
        appendProtoOther(
            from: template,
            excluding: ["name", "ord", "qfmt", "afmt", "bqfmt", "bafmt", "did", "bfont", "bsize", "id", "mod", "usn"],
            to: &configFields
        )
        return ProtoWriter.message(configFields)
    }

    private func encodeDeckCommon(_ deck: [String: Any]) -> Data {
        let new = dayCount(deck["newToday"])
        let review = dayCount(deck["revToday"])
        let learning = dayCount(deck["lrnToday"])
        let time = dayCount(deck["timeToday"])
        let day = max(max(new.day, review.day), max(learning.day, time.day))
        var fields = [
            ProtoWriter.bool(field: 1, value: deck["collapsed"] as? Bool ?? false),
            ProtoWriter.bool(field: 2, value: deck["browserCollapsed"] as? Bool ?? false),
            ProtoWriter.uint(field: 3, value: UInt64(max(0, day))),
            ProtoWriter.uint(field: 4, value: UInt64(new.day == day ? max(0, new.count) : 0)),
            ProtoWriter.uint(field: 5, value: UInt64(review.day == day ? max(0, review.count) : 0)),
            ProtoWriter.uint(field: 6, value: UInt64(learning.day == day ? max(0, learning.count) : 0)),
            ProtoWriter.uint(field: 7, value: UInt64(time.day == day ? max(0, time.count) : 0))
        ]
        appendProtoOther(
            from: deck,
            excluding: ["id", "name", "mod", "usn", "collapsed", "browserCollapsed", "desc", "md", "dyn", "conf", "extendNew", "extendRev", "newToday", "revToday", "lrnToday", "timeToday", "terms", "resched", "previewDelay", "ankiosSearchOrder", "ankiosIncludeTags", "ankiosExcludeTags", "previewAgain", "previewHard", "previewGood", "previewAgainSecs", "previewHardSecs", "previewGoodSecs", "ankiosSearchOrder2", "desiredRetention", "newLimit", "reviewLimit", "newLimitToday", "reviewLimitToday"],
            to: &fields
        )
        return ProtoWriter.message(fields)
    }

    private func encodeDeckKind(_ deck: [String: Any]) throws -> Data {
        if integer(deck["dyn"]) != 0 {
            var fields = [ProtoWriter.bool(field: 1, value: deck["resched"] as? Bool ?? true)]
            for term in deck["terms"] as? [[Any]] ?? [] {
                guard term.count >= 3 else { continue }
                fields.append(ProtoWriter.bytes(field: 2, value: ProtoWriter.message([
                    ProtoWriter.string(field: 1, value: term[0] as? String ?? ""),
                    ProtoWriter.uint(field: 2, value: uint(term[1])),
                    ProtoWriter.uint(field: 3, value: filteredOrder(term[2] as? String ?? "due"))
                ])))
            }
            fields.append(contentsOf: [
                ProtoWriter.uint(field: 4, value: uint(deck["previewDelay"])),
                ProtoWriter.uint(field: 5, value: uint(deck["previewHardSecs"] ?? deck["previewHard"])),
                ProtoWriter.uint(field: 6, value: uint(deck["previewGoodSecs"] ?? deck["previewGood"])),
                ProtoWriter.uint(field: 7, value: uint(deck["previewAgainSecs"] ?? deck["previewAgain"]))
            ])
            return ProtoWriter.message([ProtoWriter.bytes(field: 2, value: ProtoWriter.message(fields))])
        }
        var normal = [
            ProtoWriter.uint(field: 1, value: uint(deck["conf"], fallback: 1)),
            ProtoWriter.uint(field: 2, value: uint(deck["extendNew"])),
            ProtoWriter.uint(field: 3, value: uint(deck["extendRev"])),
            ProtoWriter.string(field: 4, value: deck["desc"] as? String ?? ""),
            ProtoWriter.bool(field: 5, value: deck["md"] as? Bool ?? false)
        ]
        if let limit = deck["reviewLimit"] { normal.append(ProtoWriter.uint(field: 6, value: uint(limit))) }
        if let limit = deck["newLimit"] { normal.append(ProtoWriter.uint(field: 7, value: uint(limit))) }
        if let today = deck["reviewLimitToday"] as? [String: Any] {
            normal.append(ProtoWriter.bytes(field: 8, value: ProtoWriter.message([
                ProtoWriter.uint(field: 1, value: uint(today["limit"])),
                ProtoWriter.uint(field: 2, value: uint(today["today"]))
            ])))
        }
        if let today = deck["newLimitToday"] as? [String: Any] {
            normal.append(ProtoWriter.bytes(field: 9, value: ProtoWriter.message([
                ProtoWriter.uint(field: 1, value: uint(today["limit"])),
                ProtoWriter.uint(field: 2, value: uint(today["today"]))
            ])))
        }
        if let retention = deck["desiredRetention"] {
            let value = number(retention)
            normal.append(ProtoWriter.float(field: 10, value: value > 1 ? value / 100 : value))
        }
        return ProtoWriter.message([ProtoWriter.bytes(field: 1, value: ProtoWriter.message(normal))])
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
    }

    private func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private func appendProtoOther(from object: [String: Any], excluding reserved: Set<String>, to fields: inout [Data]) {
        let extra = object.filter { !reserved.contains($0.key) }
        guard !extra.isEmpty, let data = try? jsonData(extra) else { return }
        fields.append(ProtoWriter.bytes(field: 255, value: data))
    }

    private func integer(_ value: Any?, fallback: Int = 0) -> Int {
        (value as? NSNumber)?.intValue ?? fallback
    }

    private func integer64(_ value: Any?, fallback: Int64 = 0) -> Int64 {
        (value as? NSNumber)?.int64Value ?? fallback
    }

    private func uint(_ value: Any?, fallback: UInt64 = 0) -> UInt64 {
        UInt64(max(0, integer(value, fallback: Int(min(fallback, UInt64(Int.max))))))
    }

    private func uintAt(_ value: Any?, _ index: Int, fallback: UInt64) -> UInt64 {
        guard let values = value as? [Any], values.indices.contains(index) else { return fallback }
        return uint(values[index], fallback: fallback)
    }

    private func number(_ value: Any?, fallback: Double = 0) -> Double {
        (value as? NSNumber)?.doubleValue ?? fallback
    }

    private func numbers(_ value: Any?) -> [Double] {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    }

    private func dayCount(_ value: Any?) -> (day: Int, count: Int) {
        guard let pair = value as? [Any], pair.count >= 2 else { return (0, 0) }
        return (integer(pair[0]), integer(pair[1]))
    }

    private func filteredOrder(_ value: String) -> UInt64 {
        switch value {
        case "oldest": return 0
        case "random": return 1
        case "ivl": return 2
        case "ivlDesc": return 3
        case "lapses": return 4
        case "added": return 5
        case "due": return 6
        case "latest": return 7
        case "retrievability": return 8
        case "retrievabilityDesc": return 9
        case "relative": return 10
        default: return 6
        }
    }

    private func modernReviewOrder(_ legacy: Int) -> UInt64 {
        UInt64(max(0, legacy))
    }

    private func modernGatherPriority(_ legacy: Int) -> UInt64 {
        UInt64(max(0, legacy))
    }

    private func resetScheduling(at url: URL, includeDeckPresets: Bool) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.run("DELETE FROM revlog")

        var cards: [(id: Int64, type: Int, due: Int, originalDue: Int, originalDeckID: Int64, data: String)] = []
        try db.query("SELECT id, type, due, odue, odid, data FROM cards ORDER BY id") { stmt in
            cards.append((
                sqlite3_column_int64(stmt, 0),
                Int(sqlite3_column_int(stmt, 1)),
                Int(sqlite3_column_int(stmt, 2)),
                Int(sqlite3_column_int(stmt, 3)),
                sqlite3_column_int64(stmt, 4),
                SQLiteDatabase.text(stmt, 5)
            ))
        }
        let configuredNextPosition: Int
        if let confJSON = try db.scalarText("SELECT conf FROM col"),
           let conf = try JSONSerialization.jsonObject(with: Data(confJSON.utf8)) as? [String: Any] {
            configuredNextPosition = max(1, (conf["nextPos"] as? NSNumber)?.intValue ?? 1)
        } else {
            configuredNextPosition = 1
        }
        var nextPosition = configuredNextPosition
        for card in cards {
            let originalPosition: Int?
            if card.type == 0 {
                originalPosition = card.originalDeckID != 0 ? card.originalDue : card.due
            } else if let data = try? JSONSerialization.jsonObject(with: Data(card.data.utf8)) as? [String: Any],
                      let position = data["pos"] as? NSNumber {
                originalPosition = position.intValue
            } else {
                originalPosition = nil
            }
            let due: Int
            if let originalPosition {
                due = max(0, originalPosition)
            } else {
                due = nextPosition
                nextPosition += 1
            }
            var data = (try? JSONSerialization.jsonObject(with: Data(card.data.utf8))) as? [String: Any] ?? [:]
            data.removeValue(forKey: "pos")
            data.removeValue(forKey: "s")
            data.removeValue(forKey: "d")
            let dataJSON = CollectionSchema.encodeJSON(data)
            try db.run("UPDATE cards SET type=0, queue=0, due=?, ivl=0, factor=0, reps=0, lapses=0, odid=0, odue=0, flags=0, data=? WHERE id=?") { stmt in
                SQLiteDatabase.bindInt(stmt, 1, due)
                try SQLiteDatabase.bindText(stmt, 2, dataJSON)
                SQLiteDatabase.bindInt64(stmt, 3, card.id)
            }
        }

        var notes: [(id: Int64, tags: String)] = []
        try db.query("SELECT id, tags FROM notes") { stmt in
            notes.append((sqlite3_column_int64(stmt, 0), SQLiteDatabase.text(stmt, 1)))
        }
        for note in notes {
            let tags = AnkiTag.split(note.tags)
                .filter { !["marked", "leech"].contains($0.lowercased()) }
            let tagString = tags.isEmpty ? "" : " \(tags.joined(separator: " ")) "
            try db.run("UPDATE notes SET tags=? WHERE id=?") { update in
                try SQLiteDatabase.bindText(update, 1, tagString)
                SQLiteDatabase.bindInt64(update, 2, note.id)
            }
        }

        if let decksJSON = try db.scalarText("SELECT decks FROM col"),
           var decks = try JSONSerialization.jsonObject(with: Data(decksJSON.utf8)) as? [String: Any] {
            for (key, rawDeck) in decks {
                guard var deck = rawDeck as? [String: Any] else { continue }
                let wasFiltered = integer(deck["dyn"]) != 0
                deck["collapsed"] = false
                deck["browserCollapsed"] = false
                deck["newToday"] = [0, 0]
                deck["revToday"] = [0, 0]
                deck["lrnToday"] = [0, 0]
                deck["timeToday"] = [0, 0]
                deck["extendNew"] = 0
                deck["extendRev"] = 0
                deck["dyn"] = 0
                deck.removeValue(forKey: "reviewLimit")
                deck.removeValue(forKey: "newLimit")
                deck.removeValue(forKey: "reviewLimitToday")
                deck.removeValue(forKey: "newLimitToday")
                if wasFiltered {
                    deck["conf"] = 1
                    deck["desc"] = ""
                    deck.removeValue(forKey: "md")
                }
                let packageKeys: Set<String> = [
                    "id", "name", "mod", "usn", "collapsed", "browserCollapsed", "desc", "md", "dyn",
                    "conf", "extendNew", "extendRev", "newToday", "revToday", "lrnToday", "timeToday",
                    "desiredRetention"
                ]
                deck = deck.filter { packageKeys.contains($0.key) }
                if !includeDeckPresets && !wasFiltered {
                    deck["conf"] = 1
                }
                decks[key] = deck
            }
            try db.run("UPDATE col SET decks=?", bind: {
                try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(decks))
            })
        }
    }

    private func stripDeckPresets(at url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        let defaultConfig = CollectionSchema.encodeJSON([
            "1": CollectionSchema.defaultDconf(id: 1, now: Int64(Date().timeIntervalSince1970))
        ])
        try db.run("UPDATE col SET dconf=?", bind: {
            try SQLiteDatabase.bindText($0, 1, defaultConfig)
        })
        if let decksJSON = try db.scalarText("SELECT decks FROM col"),
           var decks = try JSONSerialization.jsonObject(with: Data(decksJSON.utf8)) as? [String: Any] {
            for (key, rawDeck) in decks {
                guard var deck = rawDeck as? [String: Any] else { continue }
                deck["conf"] = 1
                decks[key] = deck
            }
            try db.run("UPDATE col SET decks=?", bind: {
                try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(decks))
            })
        }
    }

    private func stripFSRSParameters(at url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        guard let json = try db.scalarText("SELECT dconf FROM col"),
              var configs = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        for (key, rawConfig) in configs {
            guard var config = rawConfig as? [String: Any] else { continue }
            config.removeValue(forKey: "fsrsWeights")
            config.removeValue(forKey: "fsrsParams5")
            config.removeValue(forKey: "fsrsParams6")
            configs[key] = config
        }
        try db.run("UPDATE col SET dconf=?", bind: {
            try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(configs))
        })
    }

    private func filterDatabase(at url: URL, deckID: Int64) throws {
        let db = try SQLiteDatabase(path: url.path)
        let ids = store.deckTreeIDs(including: deckID)
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        try db.exec("CREATE TEMP TABLE selected_export_notes (id INTEGER PRIMARY KEY)")
        try db.run("""
            INSERT OR IGNORE INTO selected_export_notes (id)
            SELECT DISTINCT nid FROM cards
            WHERE did IN (\(ph)) OR (odid != 0 AND odid IN (\(ph)))
        """) { stmt in
            for pass in 0..<2 {
                for (i, id) in ids.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(pass * ids.count + i + 1), id)
                }
            }
        }
        try filterDatabase(
            db: db,
            keepNotesSQL: "id IN (SELECT id FROM selected_export_notes)",
            bind: { _ in },
            keepNotesWithoutCards: false
        )
    }

    private func filterDatabase(at url: URL, cardIDs: [Int64]) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.run("CREATE TEMP TABLE selected_export_cards (id INTEGER PRIMARY KEY)")
        for start in stride(from: 0, to: cardIDs.count, by: 500) {
            let batch = Array(cardIDs[start..<min(start + 500, cardIDs.count)])
            let placeholders = batch.map { _ in "(?)" }.joined(separator: ",")
            try db.run("INSERT OR IGNORE INTO selected_export_cards (id) VALUES \(placeholders)", bind: { stmt in
                for (index, id) in batch.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id)
                }
            })
        }
        try db.exec("CREATE TEMP TABLE selected_export_notes (id INTEGER PRIMARY KEY)")
        try db.exec("""
            INSERT OR IGNORE INTO selected_export_notes (id)
            SELECT DISTINCT nid FROM cards WHERE id IN (SELECT id FROM selected_export_cards)
        """)
        try filterDatabase(
            db: db,
            keepNotesSQL: "id IN (SELECT id FROM selected_export_notes)",
            bind: { _ in },
            keepNotesWithoutCards: false
        )
    }

    private func filterDatabase(
        at url: URL,
        keepNotesSQL: String,
        bind: @escaping (OpaquePointer) throws -> Void,
        keepNotesWithoutCards: Bool
    ) throws {
        let db = try SQLiteDatabase(path: url.path)
        try filterDatabase(
            db: db,
            keepNotesSQL: keepNotesSQL,
            bind: bind,
            keepNotesWithoutCards: keepNotesWithoutCards
        )
    }

    private func filterDatabase(
        db: SQLiteDatabase,
        keepNotesSQL: String,
        bind: @escaping (OpaquePointer) throws -> Void,
        keepNotesWithoutCards: Bool
    ) throws {
        try db.run("DELETE FROM cards WHERE nid NOT IN (SELECT id FROM notes WHERE \(keepNotesSQL))", bind: bind)
        if !keepNotesWithoutCards {
            try db.run("DELETE FROM notes WHERE NOT (\(keepNotesSQL))", bind: bind)
        }
        try db.run("DELETE FROM revlog WHERE cid NOT IN (SELECT id FROM cards)")
    }

    private func prunePackageMetadata(at url: URL, includeDefaultDeck: Bool) throws {
        let db = try SQLiteDatabase(path: url.path)
        var exportedDeckIDs = Set<Int64>()
        try db.query("SELECT DISTINCT did FROM cards") { stmt in
            exportedDeckIDs.insert(sqlite3_column_int64(stmt, 0))
        }
        try db.query("SELECT DISTINCT odid FROM cards WHERE odid != 0") { stmt in
            exportedDeckIDs.insert(sqlite3_column_int64(stmt, 0))
        }

        if let decksJSON = try db.scalarText("SELECT decks FROM col"),
           var decks = try JSONSerialization.jsonObject(with: Data(decksJSON.utf8)) as? [String: Any] {
            var decksByID: [Int64: [String: Any]] = [:]
            var deckIDsByName: [String: Int64] = [:]
            for (key, rawDeck) in decks {
                guard let id = Int64(key), let deck = rawDeck as? [String: Any] else { continue }
                decksByID[id] = deck
                if let name = deck["name"] as? String {
                    deckIDsByName[name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))] = id
                }
            }
            for id in Array(exportedDeckIDs) {
                guard let name = decksByID[id]?["name"] as? String else { continue }
                let parts = name.components(separatedBy: "::")
                guard parts.count > 1 else { continue }
                for count in 1..<parts.count {
                    let parent = parts.prefix(count).joined(separator: "::")
                    let key = parent.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    if let parentID = deckIDsByName[key] {
                        exportedDeckIDs.insert(parentID)
                    }
                }
            }
            if !includeDefaultDeck {
                exportedDeckIDs.remove(1)
            }
            let keep = Set(exportedDeckIDs.map(String.init))
            decks = decks.filter { keep.contains($0.key) }
            try db.run("UPDATE col SET decks = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(decks))
            })

            let usedConfigIDs = Set(decks.values.compactMap { rawDeck -> String? in
                guard let deck = rawDeck as? [String: Any],
                      ((deck["dyn"] as? NSNumber)?.intValue ?? 0) == 0,
                      let configID = CollectionStore.int64(deck["conf"]) else { return nil }
                return String(configID)
            })
            if let configsJSON = try db.scalarText("SELECT dconf FROM col"),
               var configs = try JSONSerialization.jsonObject(with: Data(configsJSON.utf8)) as? [String: Any] {
                configs = configs.filter { usedConfigIDs.contains($0.key) }
                try db.run("UPDATE col SET dconf = ?", bind: {
                    try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(configs))
                })
            }
        }

        if let modelsJSON = try db.scalarText("SELECT models FROM col"),
           var models = try JSONSerialization.jsonObject(with: Data(modelsJSON.utf8)) as? [String: Any] {
            var usedModelIDs = Set<String>()
            try db.query("SELECT DISTINCT mid FROM notes") { stmt in
                usedModelIDs.insert(String(sqlite3_column_int64(stmt, 0)))
            }
            models = models.filter { usedModelIDs.contains($0.key) }
            try db.run("UPDATE col SET models = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(models))
            })
        }
    }

    private func clearPackageLocalState(at url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        let sourceConf = try jsonObject(db.scalarText("SELECT conf FROM col") ?? "{}")
        let conf: [String: Any] = [
            "activeDecks": [1],
            "curDeck": 1,
            "newSpread": 0,
            "collapseTime": 1200,
            "timeLim": 0,
            "estTimes": true,
            "dueCounts": true,
            "curModel": NSNull(),
            "nextPos": 1,
            "sortType": "noteFld",
            "sortBackwards": false,
            "addToCur": true,
            "dayLearnFirst": false,
            "schedVer": 2,
            "creationOffset": sourceConf["creationOffset"] ?? NSNull(),
            "sched2021": true
        ]
        try db.run("UPDATE col SET conf=?, tags='{}'", bind: {
            try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(conf))
        })
    }

    private func mediaUsed(byDeck deckID: Int64) throws -> Set<String> {
        let ids = store.deckTreeIDs(including: deckID)
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        var fldsAll = ""
        var notetypeIDs = Set<Int64>()
        try store.db.query("""
            SELECT n.flds, n.mid FROM notes n JOIN cards c ON c.nid = n.id
            WHERE c.did IN (\(ph)) OR (c.odid != 0 AND c.odid IN (\(ph)))
        """) { stmt in
            for pass in 0..<2 {
                for (i, id) in ids.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(pass * ids.count + i + 1), id)
                }
            }
        } map: { stmt in
            fldsAll += SQLiteDatabase.text(stmt, 0) + " "
            notetypeIDs.insert(sqlite3_column_int64(stmt, 1))
        }
        return referencedMedia(in: fldsAll, notetypeIDs: notetypeIDs)
    }

    private func mediaUsed(byCards cardIDs: [Int64]) throws -> Set<String> {
        guard !cardIDs.isEmpty else { return [] }
        var fldsAll = ""
        var notetypeIDs = Set<Int64>()
        for start in stride(from: 0, to: cardIDs.count, by: 500) {
            let batch = Array(cardIDs[start..<min(start + 500, cardIDs.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try store.db.query("""
                SELECT n.flds, n.mid FROM notes n JOIN cards c ON c.nid = n.id WHERE c.id IN (\(placeholders))
            """) { stmt in
                for (index, id) in batch.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id)
                }
            } map: { stmt in
                fldsAll += SQLiteDatabase.text(stmt, 0) + " "
                notetypeIDs.insert(sqlite3_column_int64(stmt, 1))
            }
        }
        return referencedMedia(in: fldsAll, notetypeIDs: notetypeIDs)
    }

    private func mediaUsedByCollection() throws -> Set<String> {
        var fldsAll = ""
        var notetypeIDs = Set<Int64>()
        try store.db.query("SELECT flds, mid FROM notes") { _ in } map: { stmt in
            fldsAll += SQLiteDatabase.text(stmt, 0) + " "
            notetypeIDs.insert(sqlite3_column_int64(stmt, 1))
        }
        return referencedMedia(in: fldsAll, notetypeIDs: notetypeIDs)
    }

    private func referencedMedia(in fields: String, notetypeIDs: Set<Int64>) -> Set<String> {
        var references = Set(MediaStore.mediaFiles(in: fields))
        for id in notetypeIDs {
            guard let notetype = store.notetype(id: id) else { continue }
            let templates = notetype.tmpls.map { $0.qfmt + $0.afmt + $0.bqfmt + $0.bafmt }.joined(separator: " ")
            references.formUnion(MediaStore.mediaFiles(in: notetype.css + " " + templates))
        }
        return references
    }

    private func zipFolder(_ folder: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)
        try ZipWriter.createStoredZip(of: folder, to: destination)
    }

    private func makeDummyCollection(at url: URL) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.exec(CollectionSchema.createSQL)
        let empty = CollectionSchema.emptyColJSON()
        let now = Int64(Date().timeIntervalSince1970)
        let models = try JSONSerialization.jsonObject(with: Data(empty.models.utf8)) as? [String: [String: Any]] ?? [:]
        guard let model = models.values.first, let modelID = (model["id"] as? NSNumber)?.int64Value else {
            throw ImportError.decodeFailed("Não foi possível preparar os metadados do pacote de coleção.")
        }
        try db.run("""
            INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
            VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, ?)
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, now)
            SQLiteDatabase.bindInt64(stmt, 2, now * 1000)
            SQLiteDatabase.bindInt64(stmt, 3, now * 1000)
            try SQLiteDatabase.bindText(stmt, 4, empty.conf)
            try SQLiteDatabase.bindText(stmt, 5, empty.models)
            try SQLiteDatabase.bindText(stmt, 6, empty.decks)
            try SQLiteDatabase.bindText(stmt, 7, empty.dconf)
            try SQLiteDatabase.bindText(stmt, 8, empty.tags)
        }
        let warning = "Please update to the latest Anki."
        try db.run("""
            INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
            VALUES (1, ?, ?, ?, -1, ' ', ?, ?, 0, 0, '')
        """) { stmt in
            try SQLiteDatabase.bindText(stmt, 1, UUID().uuidString)
            SQLiteDatabase.bindInt64(stmt, 2, modelID)
            SQLiteDatabase.bindInt64(stmt, 3, now)
            try SQLiteDatabase.bindText(stmt, 4, warning + "\u{001f}")
            try SQLiteDatabase.bindText(stmt, 5, warning)
        }
        try db.run("""
            INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
            VALUES (1, 1, 1, 0, ?, -1, 0, 0, 0, 0, 2500, 0, 0, 0, 0, 0, 0, '')
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, now)
        }
        try db.exec("PRAGMA page_size=512; PRAGMA journal_mode=DELETE; VACUUM;")
        db.closeConnection()
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }
}

private enum ProtoWriter {
    static func message(_ fields: [Data]) -> Data {
        fields.reduce(into: Data()) { $0.append($1) }
    }

    static func uint(field: Int, value: UInt64) -> Data {
        var data = varint(UInt64(field << 3))
        data.append(varint(value))
        return data
    }

    static func bool(field: Int, value: Bool) -> Data {
        uint(field: field, value: value ? 1 : 0)
    }

    static func sint32(field: Int, value: Int32) -> Data {
        let zigzag = UInt64(UInt32(bitPattern: (value &<< 1) ^ (value >> 31)))
        return uint(field: field, value: zigzag)
    }

    static func float(field: Int, value: Double) -> Data {
        let bits = Float(value).bitPattern
        var data = varint(UInt64((field << 3) | 5))
        data.append(contentsOf: bits.littleEndianBytes)
        return data
    }

    static func floats(field: Int, values: [Double]) -> Data {
        guard !values.isEmpty else { return Data() }
        var payload = Data()
        for value in values { payload.append(contentsOf: Float(value).bitPattern.littleEndianBytes) }
        return bytes(field: field, value: payload)
    }

    static func packedUInt(field: Int, values: [UInt64]) -> Data {
        guard !values.isEmpty else { return Data() }
        let payload = values.reduce(into: Data()) { $0.append(varint($1)) }
        return bytes(field: field, value: payload)
    }

    static func string(field: Int, value: String) -> Data {
        bytes(field: field, value: Data(value.utf8))
    }

    static func bytes(field: Int, value: Data) -> Data {
        var data = varint(UInt64((field << 3) | 2))
        data.append(varint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        while value >= 0x80 {
            result.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        let value = littleEndian
        return [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }
}

enum ZipWriter {
    static func createStoredZip(of folder: URL, to destination: URL) throws {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])!
        let rootPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var entries: [(name: String, url: URL, size: UInt64, crc: UInt32)] = []
        for case let fileURL as URL in enumerator {
            let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { throw ImportError.decodeFailed("Caminho de arquivo inválido no pacote.") }
            let rel = String(filePath.dropFirst(rootPath.count + 1))
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            if isDir.boolValue { continue }
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            guard let fileSize = attributes[.size] as? NSNumber else {
                throw ImportError.decodeFailed("Não foi possível ler o tamanho de um arquivo do pacote.")
            }
            entries.append((rel, fileURL, fileSize.uint64Value, try crc32(of: fileURL)))
        }

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        var central = Data()
        var offset: UInt64 = 0
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            guard nameData.count <= Int(UInt16.max) else { throw ImportError.decodeFailed("Nome de arquivo inválido no pacote.") }
            let localHeaderOffset = offset
            let sizeUsesZIP64 = entry.size >= UInt64(UInt32.max)
            var localExtra = Data()
            if sizeUsesZIP64 {
                localExtra.append(contentsOf: UInt16(0x0001).leBytes)
                localExtra.append(contentsOf: UInt16(16).leBytes)
                localExtra.append(contentsOf: entry.size.leBytes)
                localExtra.append(contentsOf: entry.size.leBytes)
            }
            var local = Data()
            local.append(contentsOf: UInt32(0x04034b50).leBytes)
            local.append(contentsOf: UInt16(sizeUsesZIP64 ? 45 : 20).leBytes)
            local.append(contentsOf: UInt16(0).leBytes) // flags
            local.append(contentsOf: UInt16(0).leBytes) // method store
            local.append(contentsOf: UInt16(0).leBytes) // time
            local.append(contentsOf: UInt16(0).leBytes) // date
            local.append(contentsOf: entry.crc.leBytes)
            let size32 = sizeUsesZIP64 ? UInt32.max : UInt32(entry.size)
            local.append(contentsOf: size32.leBytes)
            local.append(contentsOf: size32.leBytes)
            local.append(contentsOf: UInt16(nameData.count).leBytes)
            local.append(contentsOf: UInt16(localExtra.count).leBytes)
            local.append(nameData)
            local.append(localExtra)
            try output.write(contentsOf: local)
            let input = try FileHandle(forReadingFrom: entry.url)
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try input.close()
            let (nextOffset, overflow) = offset.addingReportingOverflow(UInt64(local.count) + entry.size)
            guard !overflow else { throw ImportError.decodeFailed("O pacote excede o limite de tamanho suportado.") }
            offset = nextOffset

            let offsetUsesZIP64 = localHeaderOffset >= UInt64(UInt32.max)
            let centralExtraLength = (sizeUsesZIP64 ? 16 : 0) + (offsetUsesZIP64 ? 8 : 0)
            var centralExtra = Data()
            if centralExtraLength > 0 {
                centralExtra.append(contentsOf: UInt16(0x0001).leBytes)
                centralExtra.append(contentsOf: UInt16(centralExtraLength).leBytes)
                if sizeUsesZIP64 {
                    centralExtra.append(contentsOf: entry.size.leBytes)
                    centralExtra.append(contentsOf: entry.size.leBytes)
                }
                if offsetUsesZIP64 { centralExtra.append(contentsOf: localHeaderOffset.leBytes) }
            }
            var cen = Data()
            cen.append(contentsOf: UInt32(0x02014b50).leBytes)
            cen.append(contentsOf: UInt16(sizeUsesZIP64 || offsetUsesZIP64 ? 45 : 20).leBytes)
            cen.append(contentsOf: UInt16(sizeUsesZIP64 || offsetUsesZIP64 ? 45 : 20).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: entry.crc.leBytes)
            cen.append(contentsOf: (sizeUsesZIP64 ? UInt32.max : UInt32(entry.size)).leBytes)
            cen.append(contentsOf: (sizeUsesZIP64 ? UInt32.max : UInt32(entry.size)).leBytes)
            cen.append(contentsOf: UInt16(nameData.count).leBytes)
            cen.append(contentsOf: UInt16(centralExtra.count).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt16(0).leBytes)
            cen.append(contentsOf: UInt32(0).leBytes)
            cen.append(contentsOf: (offsetUsesZIP64 ? UInt32.max : UInt32(localHeaderOffset)).leBytes)
            cen.append(nameData)
            cen.append(centralExtra)
            central.append(cen)
        }
        let centralOffset = offset
        let (zip64EOCDOffset, offsetOverflow) = centralOffset.addingReportingOverflow(UInt64(central.count))
        guard !offsetOverflow else { throw ImportError.decodeFailed("O pacote excede o limite de tamanho suportado.") }
        try output.write(contentsOf: central)
        let needsZIP64 = entries.count >= Int(UInt16.max)
            || central.count >= Int(UInt32.max)
            || centralOffset >= UInt64(UInt32.max)
            || zip64EOCDOffset >= UInt64(UInt32.max)
            || entries.contains { $0.size >= UInt64(UInt32.max) }
        if needsZIP64 {
            var zip64 = Data()
            zip64.append(contentsOf: UInt32(0x06064b50).leBytes)
            zip64.append(contentsOf: UInt64(44).leBytes)
            zip64.append(contentsOf: UInt16(45).leBytes)
            zip64.append(contentsOf: UInt16(45).leBytes)
            zip64.append(contentsOf: UInt32(0).leBytes)
            zip64.append(contentsOf: UInt32(0).leBytes)
            zip64.append(contentsOf: UInt64(entries.count).leBytes)
            zip64.append(contentsOf: UInt64(entries.count).leBytes)
            zip64.append(contentsOf: UInt64(central.count).leBytes)
            zip64.append(contentsOf: centralOffset.leBytes)
            try output.write(contentsOf: zip64)

            var locator = Data()
            locator.append(contentsOf: UInt32(0x07064b50).leBytes)
            locator.append(contentsOf: UInt32(0).leBytes)
            locator.append(contentsOf: zip64EOCDOffset.leBytes)
            locator.append(contentsOf: UInt32(1).leBytes)
            try output.write(contentsOf: locator)
        }
        var end = Data()
        end.append(contentsOf: UInt32(0x06054b50).leBytes)
        end.append(contentsOf: UInt16(0).leBytes)
        end.append(contentsOf: UInt16(0).leBytes)
        let count16 = needsZIP64 ? UInt16.max : UInt16(entries.count)
        end.append(contentsOf: count16.leBytes)
        end.append(contentsOf: count16.leBytes)
        end.append(contentsOf: (needsZIP64 ? UInt32.max : UInt32(central.count)).leBytes)
        end.append(contentsOf: (needsZIP64 ? UInt32.max : UInt32(centralOffset)).leBytes)
        end.append(contentsOf: UInt16(0).leBytes)
        try output.write(contentsOf: end)
    }

    private static func crc32(of url: URL) throws -> UInt32 {
        var crc: UInt32 = 0xffffffff
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            for byte in chunk {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    if crc & 1 != 0 {
                        crc = (crc >> 1) ^ 0xedb88320
                    } else {
                        crc >>= 1
                    }
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
private extension UInt64 {
    var leBytes: [UInt8] {
        [UInt8(self & 0xff), UInt8((self >> 8) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 24) & 0xff),
         UInt8((self >> 32) & 0xff), UInt8((self >> 40) & 0xff), UInt8((self >> 48) & 0xff), UInt8((self >> 56) & 0xff)]
    }
}
