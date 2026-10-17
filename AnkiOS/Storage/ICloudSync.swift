import Foundation
import CryptoKit
import SQLite3

enum ICloudSyncError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iCloud não está disponível. Entre na mesma conta Apple neste aparelho. O contêiner iCloud.com.bigbear.AnkiOS precisa estar ligado neste app."
        case .failed(let message):
            return message
        }
    }
}

/// Copies profile collections through iCloud Drive and reconciles media and collection rows.
enum ICloudSync {
    static let containerID = "iCloud.com.bigbear.AnkiOS"
    private static let profileManifestName = ".ankios-icloud-profiles.json"
    private static let profileCreatedName = ".ankios-created-at"

    private struct ProfileManifest: Codable {
        var deletedAt: [String: Int64]
    }

    static func sync(localProfiles: URL) throws -> String {
        let syncLock = try SharedCollectionFileLock.acquire(profilesRoot: localProfiles)
        defer { syncLock.release() }
        return try sync(localProfiles: localProfiles, lock: syncLock)
    }

    static func sync(localProfiles: URL, lock: SharedCollectionFileLock.Token) throws -> String {
        let fm = FileManager.default
        guard let container = fm.url(forUbiquityContainerIdentifier: containerID) else {
            throw ICloudSyncError.unavailable
        }
        let cloudProfiles = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
        try fm.createDirectory(at: localProfiles, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloudProfiles, withIntermediateDirectories: true)

        try downloadIfNeeded(cloudProfiles.appendingPathComponent(profileManifestName))
        var manifest = readProfileManifest(at: localProfiles)
        for (name, timestamp) in readProfileManifest(at: cloudProfiles).deletedAt {
            manifest.deletedAt[name] = max(manifest.deletedAt[name] ?? 0, timestamp)
        }
        let profileNames = Set(directoryNames(at: localProfiles) + directoryNames(at: cloudProfiles))
        for name in profileNames {
            let local = localProfiles.appendingPathComponent(name, isDirectory: true)
            let cloud = cloudProfiles.appendingPathComponent(name, isDirectory: true)
            try downloadIfNeeded(cloud.appendingPathComponent(profileCreatedName))
            let createdAt = max(profileCreationDate(at: local), profileCreationDate(at: cloud))
            guard let deletedAt = manifest.deletedAt[name] else { continue }
            if createdAt > deletedAt {
                manifest.deletedAt.removeValue(forKey: name)
            } else {
                if fm.fileExists(atPath: local.path) { try removeItem(at: local) }
                if fm.fileExists(atPath: cloud.path) { try removeItem(at: cloud) }
            }
        }
        try writeProfileManifest(manifest, to: localProfiles)
        try writeProfileManifest(manifest, to: cloudProfiles)

        let names = Set(directoryNames(at: localProfiles) + directoryNames(at: cloudProfiles))
        let profiles = names.isEmpty ? ["User 1"] : names.sorted()

        var sent = 0
        var received = 0
        var media = 0
        var conflictBackups = 0
        for name in profiles {
            let result = try syncProfile(
                name,
                localRoot: localProfiles,
                cloudRoot: cloudProfiles
            )
            sent += result.sentCollection ? 1 : 0
            received += result.receivedCollection ? 1 : 0
            media += result.mediaFiles
            conflictBackups += result.conflictBackups
        }

        if sent == 0, received == 0, media == 0, conflictBackups == 0 {
            return "iCloud já estava em dia."
        }
        var parts: [String] = []
        if sent > 0 { parts.append("coleção enviada") }
        if received > 0 { parts.append("coleção recebida") }
        if media > 0 { parts.append("\(media) arquivo(s) de mídia") }
        if conflictBackups > 0 { parts.append("\(conflictBackups) versão(ões) conflitante(s) salva(s) em Backups") }
        return "iCloud: " + parts.joined(separator: ", ") + "."
    }

    private struct ProfileResult {
        var sentCollection = false
        var receivedCollection = false
        var mediaFiles = 0
        var conflictBackups = 0
    }

    private static func syncProfile(_ name: String, localRoot: URL, cloudRoot: URL) throws -> ProfileResult {
        let fm = FileManager.default
        let local = localRoot.appendingPathComponent(name, isDirectory: true)
        let cloud = cloudRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)

        try downloadIfNeeded(cloud.appendingPathComponent(profileCreatedName))
        let createdAt = max(profileCreationDate(at: local), profileCreationDate(at: cloud))
        if createdAt > 0 {
            try writeProfileCreationDate(createdAt, to: local)
            try writeProfileCreationDate(createdAt, to: cloud)
        }

        let localDB = local.appendingPathComponent("collection.anki2")
        let cloudDB = cloud.appendingPathComponent("collection.anki2")
        try downloadIfNeeded(cloudDB)
        removeSidecars(localDB)

        var result = ProfileResult()
        let localHash = fileHash(at: localDB)
        let cloudHash = fileHash(at: cloudDB)
        if localHash == nil, cloudHash != nil {
            try copyReplacing(from: cloudDB, to: localDB)
            result.receivedCollection = true
        } else if cloudHash == nil, localHash != nil {
            try copyReplacing(from: localDB, to: cloudDB)
            result.sentCollection = true
        } else if let localHash, let cloudHash, localHash != cloudHash {
            try saveConflictCopy(of: localDB, in: local)
            try saveConflictCopy(of: cloudDB, in: cloud)
            result.conflictBackups += 2
            try mergeCollections(local: localDB, cloud: cloudDB)
            result.sentCollection = true
            result.receivedCollection = true
        }
        result.mediaFiles = try syncMedia(
            local: local.appendingPathComponent("collection.media", isDirectory: true),
            cloud: cloud.appendingPathComponent("collection.media", isDirectory: true),
            stateURL: local.appendingPathComponent(".ankios-icloud-media-state.json")
        )
        return result
    }

    static func mergeCollections(local: URL, cloud: URL) throws {
        let staging = local.deletingLastPathComponent()
            .appendingPathComponent(".collection-merge-\(UUID().uuidString).anki2")
        defer {
            try? FileManager.default.removeItem(at: staging)
            removeSidecars(staging)
        }
        try mergeCollectionFiles(local: local, cloud: cloud, output: staging)
        try copyLocalReplacing(from: staging, to: local)
        try copyReplacing(from: staging, to: cloud)
    }

    static func mergeCollectionFiles(local: URL, cloud: URL, output: URL) throws {
        try FileManager.default.copyItem(at: local, to: output)
        removeSidecars(output)
        let cloudStaging = output.deletingLastPathComponent()
            .appendingPathComponent(".cloud-merge-\(UUID().uuidString).anki2")
        try FileManager.default.copyItem(at: cloud, to: cloudStaging)
        removeSidecars(cloudStaging)
        defer {
            try? FileManager.default.removeItem(at: cloudStaging)
            removeSidecars(cloudStaging)
        }

        let database = try SQLiteDatabase(path: output.path)
        do {
            try database.run("ATTACH DATABASE ? AS cloud") {
                try SQLiteDatabase.bindText($0, 1, cloudStaging.path)
            }
            let localCollectionMod = try database.scalarInt64("SELECT mod FROM main.col WHERE id = 1")
            let cloudCollectionMod = try database.scalarInt64("SELECT mod FROM cloud.col WHERE id = 1")
            let preferCloudOnTies = cloudCollectionMod > localCollectionMod
            let collectionModsEqual = cloudCollectionMod == localCollectionMod
            try normalizeCloudNoteAndCardIDs(database: database)
            for table in ["notes", "cards", "revlog", "graves"] {
                let localColumns = try tableColumns(table, schema: "main", database: database)
                let cloudColumns = try tableColumns(table, schema: "cloud", database: database)
                guard localColumns.contains("id") || table == "graves",
                      Set(localColumns).isSuperset(of: table == "graves" ? ["oid", "type", "usn"] : ["id"]),
                      Set(cloudColumns).isSuperset(of: table == "graves" ? ["oid", "type", "usn"] : ["id"]) else {
                    throw ICloudSyncError.failed("As coleções têm esquemas incompatíveis na tabela \(table).")
                }
                let columns = localColumns.filter(cloudColumns.contains)
                guard !columns.isEmpty else { continue }
                try mergeRows(table: table, columns: columns, preferCloudOnTies: preferCloudOnTies, collectionModsEqual: collectionModsEqual, database: database)
            }
            try mergeCollectionMetadata(database: database, collectionModsEqual: collectionModsEqual)
            try applyGraves(database: database)
            try database.exec("DETACH DATABASE cloud;")
            try database.exec("PRAGMA wal_checkpoint(TRUNCATE);")
            database.closeConnection()
        } catch {
            database.closeConnection()
            throw error
        }
        removeSidecars(output)
    }

    private static func normalizeCloudNoteAndCardIDs(database: SQLiteDatabase) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var nextNoteID = max(now, try maximumID(table: "notes", database: database) + 1)
        var nextCardID = max(now, try maximumID(table: "cards", database: database) + 1)
        var noteIDs: [Int64: Int64] = [:]
        var noteRemaps: [(source: Int64, destination: Int64)] = []
        var incomingNotes: [(id: Int64, guid: String)] = []
        try database.query("SELECT id, guid FROM cloud.notes ORDER BY id") { statement in
            incomingNotes.append((sqlite3_column_int64(statement, 0), SQLiteDatabase.text(statement, 1)))
        }
        for note in incomingNotes {
            var localID: Int64?
            try database.query("SELECT id FROM main.notes WHERE guid = ? LIMIT 1", bind: { statement in
                try SQLiteDatabase.bindText(statement, 1, note.guid)
            }) { statement in
                localID = sqlite3_column_int64(statement, 0)
            }
            if let localID {
                noteIDs[note.id] = localID
                if localID != note.id { noteRemaps.append((note.id, localID)) }
                continue
            }
            var collides = false
            try database.query("SELECT 1 FROM main.notes WHERE id = ? LIMIT 1", bind: { statement in
                SQLiteDatabase.bindInt64(statement, 1, note.id)
            }) { _ in
                collides = true
            }
            if collides {
                while try idExists(table: "notes", id: nextNoteID, database: database) { nextNoteID += 1 }
                noteIDs[note.id] = nextNoteID
                noteRemaps.append((note.id, nextNoteID))
                nextNoteID += 1
            }
        }
        for (index, remap) in noteRemaps.enumerated() {
            try updateID(table: "notes", id: remap.source, to: Int64.min + Int64(index), database: database)
        }
        for (index, remap) in noteRemaps.enumerated() {
            try updateID(table: "notes", id: Int64.min + Int64(index), to: remap.destination, database: database)
        }

        var cardIDs: [Int64: Int64] = [:]
        var cardRemaps: [(source: Int64, destination: Int64, nid: Int64)] = []
        var incomingCards: [(id: Int64, nid: Int64, ord: Int)] = []
        try database.query("SELECT id, nid, ord FROM cloud.cards ORDER BY id") { statement in
            incomingCards.append((sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1), Int(sqlite3_column_int(statement, 2))))
        }
        for card in incomingCards {
            let nid = noteIDs[card.nid] ?? card.nid
            var matchingCardID: Int64?
            try database.query("SELECT id FROM main.cards WHERE nid = ? AND ord = ? LIMIT 1", bind: { statement in
                SQLiteDatabase.bindInt64(statement, 1, nid)
                SQLiteDatabase.bindInt(statement, 2, card.ord)
            }) { statement in
                matchingCardID = sqlite3_column_int64(statement, 0)
            }
            var destinationID = matchingCardID ?? card.id
            if matchingCardID == nil, try mainIDExists(table: "cards", id: card.id, database: database) {
                while try idExists(table: "cards", id: nextCardID, database: database) { nextCardID += 1 }
                destinationID = nextCardID
                nextCardID += 1
            }
            cardIDs[card.id] = destinationID
            if destinationID != card.id {
                cardRemaps.append((card.id, destinationID, nid))
            } else if nid != card.nid {
                try database.run("UPDATE cloud.cards SET nid = ? WHERE id = ?") { statement in
                    SQLiteDatabase.bindInt64(statement, 1, nid)
                    SQLiteDatabase.bindInt64(statement, 2, card.id)
                }
            }
        }
        for (index, remap) in cardRemaps.enumerated() {
            try updateID(table: "cards", id: remap.source, to: Int64.min + Int64(index), database: database)
        }
        for (index, remap) in cardRemaps.enumerated() {
            try database.run("UPDATE cloud.cards SET id = ?, nid = ? WHERE id = ?") { statement in
                SQLiteDatabase.bindInt64(statement, 1, remap.destination)
                SQLiteDatabase.bindInt64(statement, 2, remap.nid)
                SQLiteDatabase.bindInt64(statement, 3, Int64.min + Int64(index))
            }
        }

        let changedCards = cardIDs.filter { $0.key != $0.value }.sorted { $0.key < $1.key }
        for (index, remap) in changedCards.enumerated() {
            let temporaryID = Int64.min + Int64(index)
            try database.run("UPDATE cloud.revlog SET cid = ? WHERE cid = ?") { statement in
                SQLiteDatabase.bindInt64(statement, 1, temporaryID)
                SQLiteDatabase.bindInt64(statement, 2, remap.key)
            }
            try database.run("UPDATE cloud.graves SET oid = ? WHERE oid = ? AND type = 0") { statement in
                SQLiteDatabase.bindInt64(statement, 1, temporaryID)
                SQLiteDatabase.bindInt64(statement, 2, remap.key)
            }
        }
        for (index, remap) in changedCards.enumerated() {
            let temporaryID = Int64.min + Int64(index)
            try database.run("UPDATE cloud.revlog SET cid = ? WHERE cid = ?") { statement in
                SQLiteDatabase.bindInt64(statement, 1, remap.value)
                SQLiteDatabase.bindInt64(statement, 2, temporaryID)
            }
            try database.run("UPDATE cloud.graves SET oid = ? WHERE oid = ? AND type = 0") { statement in
                SQLiteDatabase.bindInt64(statement, 1, remap.value)
                SQLiteDatabase.bindInt64(statement, 2, temporaryID)
            }
        }
        let changedNotes = noteIDs.filter { $0.key != $0.value }.sorted { $0.key < $1.key }
        for (index, remap) in changedNotes.enumerated() {
            try database.run("UPDATE cloud.graves SET oid = ? WHERE oid = ? AND type = 1") { statement in
                SQLiteDatabase.bindInt64(statement, 1, Int64.min + Int64(index))
                SQLiteDatabase.bindInt64(statement, 2, remap.key)
            }
        }
        for (index, remap) in changedNotes.enumerated() {
            try database.run("UPDATE cloud.graves SET oid = ? WHERE oid = ? AND type = 1") { statement in
                SQLiteDatabase.bindInt64(statement, 1, remap.value)
                SQLiteDatabase.bindInt64(statement, 2, Int64.min + Int64(index))
            }
        }
    }

    private static func maximumID(table: String, database: SQLiteDatabase) throws -> Int64 {
        guard ["notes", "cards"].contains(table) else {
            throw ICloudSyncError.failed("Tabela inválida durante a reconciliação de IDs.")
        }
        let main = try database.scalarInt64("SELECT COALESCE(MAX(id), 0) FROM main.\(table)")
        let cloud = try database.scalarInt64("SELECT COALESCE(MAX(id), 0) FROM cloud.\(table)")
        return max(main, cloud)
    }

    private static func idExists(table: String, id: Int64, database: SQLiteDatabase) throws -> Bool {
        guard ["notes", "cards"].contains(table) else {
            throw ICloudSyncError.failed("Tabela inválida durante a reconciliação de IDs.")
        }
        return try database.scalarInt("""
            SELECT EXISTS(SELECT 1 FROM main.\(table) WHERE id = ?)
                 + EXISTS(SELECT 1 FROM cloud.\(table) WHERE id = ?)
            """) { statement in
            SQLiteDatabase.bindInt64(statement, 1, id)
            SQLiteDatabase.bindInt64(statement, 2, id)
        } > 0
    }

    private static func mainIDExists(table: String, id: Int64, database: SQLiteDatabase) throws -> Bool {
        guard ["notes", "cards"].contains(table) else {
            throw ICloudSyncError.failed("Tabela inválida durante a reconciliação de IDs.")
        }
        return try database.scalarInt("SELECT EXISTS(SELECT 1 FROM main.\(table) WHERE id = ?)") { statement in
            SQLiteDatabase.bindInt64(statement, 1, id)
        } > 0
    }

    private static func updateID(table: String, id: Int64, to destinationID: Int64, database: SQLiteDatabase) throws {
        guard ["notes", "cards"].contains(table) else {
            throw ICloudSyncError.failed("Tabela inválida durante a reconciliação de IDs.")
        }
        try database.run("UPDATE cloud.\(table) SET id = ? WHERE id = ?") { statement in
            SQLiteDatabase.bindInt64(statement, 1, destinationID)
            SQLiteDatabase.bindInt64(statement, 2, id)
        }
    }

    private static func tableColumns(_ table: String, schema: String, database: SQLiteDatabase) throws -> [String] {
        guard ["main", "cloud"].contains(schema), ["notes", "cards", "revlog", "graves"].contains(table) else {
            throw ICloudSyncError.failed("Nome de tabela inválido durante a sincronização.")
        }
        var columns: [String] = []
        try database.query("PRAGMA \(schema).table_info(\(table))") { statement in
            columns.append(SQLiteDatabase.text(statement, 1))
        }
        return columns
    }

    private static func mergeRows(
        table: String,
        columns: [String],
        preferCloudOnTies: Bool,
        collectionModsEqual: Bool,
        database: SQLiteDatabase
    ) throws {
        let quotedColumns = columns.map(quoteIdentifier).joined(separator: ", ")
        if table == "graves" {
            let selectedColumns = columns.map { $0 == "usn" ? "-1" : "incoming.\(quoteIdentifier($0))" }.joined(separator: ", ")
            try database.exec("""
                INSERT INTO main.graves (\(quotedColumns))
                SELECT \(selectedColumns) FROM cloud.graves AS incoming
                WHERE NOT EXISTS (
                    SELECT 1 FROM main.graves AS existing
                    WHERE existing.oid = incoming.oid AND existing.type = incoming.type
                );
            """)
            return
        }
        if table == "revlog" {
            let selectedColumns = columns.map { $0 == "usn" ? "-1" : quoteIdentifier($0) }.joined(separator: ", ")
            let signatureColumns = columns.filter { $0 != "id" && $0 != "usn" }
            let collision = signatureColumns
                .map { "existing.\(quoteIdentifier($0)) IS NOT incoming.\(quoteIdentifier($0))" }
                .joined(separator: " OR ")
            if columns.contains("id"), !signatureColumns.isEmpty {
                var collisions: [Int64] = []
                try database.query("""
                    SELECT incoming.id
                    FROM cloud.revlog AS incoming
                    JOIN main.revlog AS existing ON existing.id = incoming.id
                    WHERE \(collision)
                    ORDER BY incoming.id
                """) { statement in
                    collisions.append(sqlite3_column_int64(statement, 0))
                }
                if !collisions.isEmpty {
                    try normalizeRevlogCollisions(ids: collisions, columns: columns, database: database)
                }
            }
            try database.exec("""
                INSERT OR IGNORE INTO main.revlog (\(quotedColumns))
                SELECT \(selectedColumns) FROM cloud.revlog;
            """)
            return
        }

        guard columns.contains("mod") else {
            throw ICloudSyncError.failed("A tabela \(table) não contém o campo de revisão mod.")
        }
        let assignments = columns
            .filter { $0 != "id" && $0 != "usn" }
            .map { "\(quoteIdentifier($0)) = excluded.\(quoteIdentifier($0))" }
        let usnAssignment = columns.contains("usn") ? ", usn = -1" : ""
        let updateAssignments = assignments.joined(separator: ", ") + usnAssignment
        let selectedColumns = columns.map { $0 == "usn" ? "-1" : quoteIdentifier($0) }.joined(separator: ", ")
        let newerRowCondition: String
        if table == "cards" {
            let localReview = "COALESCE((SELECT MAX(id) FROM main.revlog WHERE cid = excluded.id), 0)"
            let cloudReview = "COALESCE((SELECT MAX(id) FROM cloud.revlog WHERE cid = excluded.id), 0)"
            let tieBreak: String
            if preferCloudOnTies {
                tieBreak = "1"
            } else if collectionModsEqual {
                tieBreak = "\(rowSignature("excluded", columns: columns)) COLLATE BINARY > \(rowSignature("main.cards", columns: columns)) COLLATE BINARY"
            } else {
                tieBreak = "0"
            }
            newerRowCondition = """
                excluded.mod > mod OR (
                    excluded.mod = mod AND (
                        \(cloudReview) > \(localReview) OR
                        (\(cloudReview) = \(localReview) AND \(tieBreak))
                    )
                )
            """
        } else if preferCloudOnTies {
            newerRowCondition = "excluded.mod >= mod"
        } else if collectionModsEqual {
            newerRowCondition = """
                excluded.mod > mod OR (
                    excluded.mod = mod AND
                    \(rowSignature("excluded", columns: columns)) COLLATE BINARY > \(rowSignature("main.notes", columns: columns)) COLLATE BINARY
                )
            """
        } else {
            newerRowCondition = "excluded.mod > mod"
        }
        try database.exec("""
            INSERT INTO main.\(table) (\(quotedColumns))
            SELECT \(selectedColumns) FROM cloud.\(table) WHERE 1
            ON CONFLICT(id) DO UPDATE SET \(updateAssignments)
            WHERE \(newerRowCondition);
        """)
    }

    private static func mergeCollectionMetadata(database: SQLiteDatabase, collectionModsEqual: Bool) throws {
        var localValues: [String: String] = [:]
        var cloudValues: [String: String] = [:]
        var localMod: Int64 = 0
        var cloudMod: Int64 = 0
        try database.query("SELECT conf, models, decks, dconf, tags, mod FROM main.col WHERE id = 1") { statement in
            localValues = ["conf": SQLiteDatabase.text(statement, 0), "models": SQLiteDatabase.text(statement, 1), "decks": SQLiteDatabase.text(statement, 2), "dconf": SQLiteDatabase.text(statement, 3), "tags": SQLiteDatabase.text(statement, 4)]
            localMod = sqlite3_column_int64(statement, 5)
        }
        try database.query("SELECT conf, models, decks, dconf, tags, mod FROM cloud.col WHERE id = 1") { statement in
            cloudValues = ["conf": SQLiteDatabase.text(statement, 0), "models": SQLiteDatabase.text(statement, 1), "decks": SQLiteDatabase.text(statement, 2), "dconf": SQLiteDatabase.text(statement, 3), "tags": SQLiteDatabase.text(statement, 4)]
            cloudMod = sqlite3_column_int64(statement, 5)
        }
        guard !localValues.isEmpty, !cloudValues.isEmpty else {
            throw ICloudSyncError.failed("Uma das coleções não tem os metadados principais do Anki.")
        }

        let preferCloudOnTies = cloudMod > localMod
        let models = try mergeObjectMaps(localValues["models"]!, cloudValues["models"]!, preferCloudOnTies: preferCloudOnTies, collectionModsEqual: collectionModsEqual)
        let decks = try mergeObjectMaps(localValues["decks"]!, cloudValues["decks"]!, preferCloudOnTies: preferCloudOnTies, collectionModsEqual: collectionModsEqual)
        let deckConfigs = try mergeObjectMaps(localValues["dconf"]!, cloudValues["dconf"]!, preferCloudOnTies: preferCloudOnTies, collectionModsEqual: collectionModsEqual)
        let tags = try mergeIntegerMaps(localValues["tags"]!, cloudValues["tags"]!)
        let conf: String
        if localMod == cloudMod {
            conf = try canonicalTieBreak(localValues["conf"]!, cloudValues["conf"]!)
        } else {
            conf = localMod > cloudMod ? localValues["conf"]! : cloudValues["conf"]!
        }
        let now = Int64(Date().timeIntervalSince1970)
        try database.run("UPDATE main.col SET conf = ?, models = ?, decks = ?, dconf = ?, tags = ?, mod = ?, usn = -1 WHERE id = 1") { statement in
            try SQLiteDatabase.bindText(statement, 1, conf)
            try SQLiteDatabase.bindText(statement, 2, models)
            try SQLiteDatabase.bindText(statement, 3, decks)
            try SQLiteDatabase.bindText(statement, 4, deckConfigs)
            try SQLiteDatabase.bindText(statement, 5, tags)
            SQLiteDatabase.bindInt64(statement, 6, max(now, max(localMod, cloudMod)))
        }
    }

    private static func mergeObjectMaps(
        _ localJSON: String,
        _ cloudJSON: String,
        preferCloudOnTies: Bool,
        collectionModsEqual: Bool
    ) throws -> String {
        guard let local = try JSONSerialization.jsonObject(with: Data(localJSON.utf8)) as? [String: [String: Any]],
              let cloud = try JSONSerialization.jsonObject(with: Data(cloudJSON.utf8)) as? [String: [String: Any]] else {
            throw ICloudSyncError.failed("Os metadados de decks ou modelos estão inválidos.")
        }
        var merged = local
        for (key, remoteValue) in cloud {
            guard let localValue = merged[key] else {
                merged[key] = remoteValue
                continue
            }
            let localTimestamp = Self.int64(localValue["mod"]) ?? 0
            let cloudTimestamp = Self.int64(remoteValue["mod"]) ?? 0
            let sameTimestampTie: Bool
            if cloudTimestamp == localTimestamp, collectionModsEqual {
                let localData = try canonicalData(localValue)
                let cloudData = try canonicalData(remoteValue)
                sameTimestampTie = cloudData != localData && !cloudData.lexicographicallyPrecedes(localData)
            } else {
                sameTimestampTie = false
            }
            if cloudTimestamp > localTimestamp || (preferCloudOnTies && cloudTimestamp == localTimestamp)
                || sameTimestampTie {
                merged[key] = remoteValue
            }
        }
        return try encodeJSON(merged)
    }

    private static func mergeIntegerMaps(_ localJSON: String, _ cloudJSON: String) throws -> String {
        guard let local = try JSONSerialization.jsonObject(with: Data(localJSON.utf8)) as? [String: Int],
              let cloud = try JSONSerialization.jsonObject(with: Data(cloudJSON.utf8)) as? [String: Int] else {
            throw ICloudSyncError.failed("O registro de tags da coleção está inválido.")
        }
        var merged = local
        for (key, value) in cloud { merged[key] = max(merged[key] ?? Int.min, value) }
        return try encodeJSON(merged)
    }

    private static func applyGraves(database: SQLiteDatabase) throws {
        try database.exec("""
            DELETE FROM main.cards WHERE id IN (SELECT oid FROM main.graves WHERE type = 0);
            DELETE FROM main.cards WHERE nid IN (SELECT oid FROM main.graves WHERE type = 1);
            DELETE FROM main.notes WHERE id IN (SELECT oid FROM main.graves WHERE type = 1);
        """)

        var deletedDeckIDs: [Int64] = []
        try database.query("SELECT DISTINCT oid FROM main.graves WHERE type = 2") { statement in
            deletedDeckIDs.append(sqlite3_column_int64(statement, 0))
        }
        guard !deletedDeckIDs.isEmpty else { return }
        var decks = try readJSONMap(database: database, column: "decks")
        for deckID in deletedDeckIDs {
            decks.removeValue(forKey: String(deckID))
            try database.run("""
                UPDATE main.cards SET
                    did = CASE WHEN did = ? THEN 1 ELSE did END,
                    due = CASE WHEN odid = ? AND odue != 0 THEN odue ELSE due END,
                    odue = CASE WHEN odid = ? THEN 0 ELSE odue END,
                    odid = CASE WHEN odid = ? THEN 0 ELSE odid END,
                    mod = ?, usn = -1
                WHERE did = ? OR odid = ?
            """) { statement in
                SQLiteDatabase.bindInt64(statement, 1, deckID)
                SQLiteDatabase.bindInt64(statement, 2, deckID)
                SQLiteDatabase.bindInt64(statement, 3, deckID)
                SQLiteDatabase.bindInt64(statement, 4, deckID)
                SQLiteDatabase.bindInt64(statement, 5, Int64(Date().timeIntervalSince1970))
                SQLiteDatabase.bindInt64(statement, 6, deckID)
                SQLiteDatabase.bindInt64(statement, 7, deckID)
            }
        }
        try database.run("UPDATE main.col SET decks = ?, mod = ?, usn = -1 WHERE id = 1") { statement in
            try SQLiteDatabase.bindText(statement, 1, encodeJSON(decks))
            SQLiteDatabase.bindInt64(statement, 2, Int64(Date().timeIntervalSince1970))
        }
    }

    private static func readJSONMap(database: SQLiteDatabase, column: String) throws -> [String: [String: Any]] {
        guard ["decks", "models", "dconf"].contains(column) else {
            throw ICloudSyncError.failed("Campo de metadados inválido.")
        }
        var result: [String: [String: Any]] = [:]
        try database.query("SELECT \(column) FROM main.col WHERE id = 1") { statement in
            guard let parsed = try JSONSerialization.jsonObject(with: Data(SQLiteDatabase.text(statement, 0).utf8)) as? [String: [String: Any]] else {
                throw ICloudSyncError.failed("Os metadados de decks estão inválidos.")
            }
            result = parsed
        }
        return result
    }

    private static func encodeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw ICloudSyncError.failed("Não foi possível codificar os metadados da coleção.")
        }
        return result
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func rowSignature(_ source: String, columns: [String]) -> String {
        columns
            .filter { $0 != "id" && $0 != "usn" }
            .map { column in
                let value = "quote(\(source).\(quoteIdentifier(column)))"
                return "printf('%d:%s', length(\(value)), \(value))"
            }
            .joined(separator: " || ")
    }

    private static func normalizeRevlogCollisions(ids: [Int64], columns: [String], database: SQLiteDatabase) throws {
        let signatureColumns = columns.filter { $0 != "id" && $0 != "usn" }
        let quotedColumns = columns.map(quoteIdentifier).joined(separator: ", ")
        let candidateColumns = quotedColumns + ", sync_sig"
        try database.exec("DROP TABLE IF EXISTS temp.sync_revlog_candidates")
        try database.exec("CREATE TEMP TABLE sync_revlog_candidates AS SELECT \(quotedColumns), '' AS sync_sig FROM main.revlog WHERE 0")

        var normalizedIDs = Set<Int64>()
        for seed in ids.sorted() where !normalizedIDs.contains(seed) {
            var pending = [seed]
            var componentIDs = Set<Int64>()
            var signatures = Set<String>()
            while let id = pending.popLast() {
                guard componentIDs.insert(id).inserted else { continue }
                for schema in ["main", "cloud"] {
                    let expression = rowSignature("\(schema).revlog", columns: signatureColumns)
                    var rowSignatures: [String] = []
                    try database.query("SELECT \(expression) FROM \(schema).revlog WHERE id = ?", bind: { statement in
                        SQLiteDatabase.bindInt64(statement, 1, id)
                    }) { statement in
                        rowSignatures.append(SQLiteDatabase.text(statement, 0))
                    }
                    for signature in rowSignatures where signatures.insert(signature).inserted {
                        for source in ["main", "cloud"] {
                            let sourceExpression = rowSignature("\(source).revlog", columns: signatureColumns)
                            try database.query("SELECT id FROM \(source).revlog WHERE \(sourceExpression) = ?", bind: { statement in
                                try SQLiteDatabase.bindText(statement, 1, signature)
                            }) { statement in
                                pending.append(sqlite3_column_int64(statement, 0))
                            }
                        }
                    }
                }
            }
            normalizedIDs.formUnion(componentIDs)

            let component = componentIDs.sorted()
            let placeholders = component.map { _ in "?" }.joined(separator: ", ")
            let bindIDs: (OpaquePointer) -> Void = { statement in
                for (index, id) in component.enumerated() {
                    SQLiteDatabase.bindInt64(statement, Int32(index + 1), id)
                }
            }
            try database.run("DELETE FROM temp.sync_revlog_candidates")
            for schema in ["main", "cloud"] {
                let expression = rowSignature("\(schema).revlog", columns: signatureColumns)
                try database.run("""
                    INSERT INTO temp.sync_revlog_candidates (\(candidateColumns))
                    SELECT \(quotedColumns), \(expression) FROM \(schema).revlog
                    WHERE id IN (\(placeholders))
                    """, bind: bindIDs)
            }
            try database.run("DELETE FROM main.revlog WHERE id IN (\(placeholders))", bind: bindIDs)

            let orderedSignatures = signatures.sorted()
            var assignedIDs = component
            var nextID = (component.max() ?? 0) + 1
            while assignedIDs.count < orderedSignatures.count {
                let occupied = try database.scalarInt64("""
                    SELECT (SELECT COUNT(*) FROM main.revlog WHERE id = ?)
                         + (SELECT COUNT(*) FROM cloud.revlog WHERE id = ?)
                    """) { statement in
                    SQLiteDatabase.bindInt64(statement, 1, nextID)
                    SQLiteDatabase.bindInt64(statement, 2, nextID)
                } > 0
                if !occupied { assignedIDs.append(nextID) }
                nextID += 1
            }

            let restoredColumns = columns.map { column -> String in
                if column == "id" { return "?" }
                if column == "usn" { return "-1" }
                return quoteIdentifier(column)
            }.joined(separator: ", ")
            for (signature, id) in zip(orderedSignatures, assignedIDs.sorted()) {
                try database.run("""
                    INSERT INTO main.revlog (\(quotedColumns))
                    SELECT \(restoredColumns) FROM temp.sync_revlog_candidates
                    WHERE sync_sig = ? LIMIT 1
                    """) { statement in
                    SQLiteDatabase.bindInt64(statement, 1, id)
                    try SQLiteDatabase.bindText(statement, 2, signature)
                }
            }
        }
        try database.exec("DROP TABLE temp.sync_revlog_candidates")
    }

    private static func canonicalData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func canonicalTieBreak(_ local: String, _ cloud: String) throws -> String {
        let localData = Data(local.utf8)
        let cloudData = Data(cloud.utf8)
        return cloudData.lexicographicallyPrecedes(localData) ? local : cloud
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int64: return value
        case let value as Int: return Int64(value)
        case let value as NSNumber: return value.int64Value
        case let value as String: return Int64(value)
        default: return nil
        }
    }

    static func recordProfileCreation(at profile: URL, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        try writeProfileCreationDate(timestamp, to: profile)
    }

    static func recordProfileDeletion(_ name: String, localProfiles: URL) throws {
        var manifest = readProfileManifest(at: localProfiles)
        manifest.deletedAt[name] = Int64(Date().timeIntervalSince1970 * 1000)
        try writeProfileManifest(manifest, to: localProfiles)
    }

    private static func readProfileManifest(at directory: URL) -> ProfileManifest {
        let url = directory.appendingPathComponent(profileManifestName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ProfileManifest.self, from: data) else {
            return ProfileManifest(deletedAt: [:])
        }
        return manifest
    }

    private static func writeProfileManifest(_ manifest: ProfileManifest, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let url = directory.appendingPathComponent(profileManifestName)
        guard (try? Data(contentsOf: url)) != data else { return }
        try coordinatedWrite(data, to: url)
    }

    private static func profileCreationDate(at directory: URL) -> Int64 {
        let url = directory.appendingPathComponent(profileCreatedName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return Int64(raw) ?? 0
    }

    private static func writeProfileCreationDate(_ timestamp: Int64, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(profileCreatedName)
        let data = Data(String(timestamp).utf8)
        guard (try? Data(contentsOf: url)) != data else { return }
        try coordinatedWrite(data, to: url)
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinationError { throw ICloudSyncError.failed(coordinationError.localizedDescription) }
        if let writeError { throw writeError }
    }

    private static func saveConflictCopy(of database: URL, in profile: URL) throws {
        let fm = FileManager.default
        let backupDirectory = profile.appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let backup = backupDirectory.appendingPathComponent("collection-conflict-\(stamp)-\(UUID().uuidString.prefix(8)).anki2")
        try copyReplacing(from: database, to: backup)
    }

    private struct MediaSyncState: Codable {
        var hashes: [String: String]
    }

    private static func syncMedia(local: URL, cloud: URL, stateURL: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let previous = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONDecoder().decode(MediaSyncState.self, from: $0) }?.hashes ?? [:]
        let names = Set(fileNames(at: local) + fileNames(at: cloud) + previous.keys)
        var copied = 0
        for name in names.sorted() {
            let localFile = local.appendingPathComponent(name)
            let cloudFile = cloud.appendingPathComponent(name)
            try downloadIfNeeded(cloudFile)
            let localHash = fileHash(at: localFile)
            let cloudHash = fileHash(at: cloudFile)
            let baselineHash = previous[name]

            switch (localHash, cloudHash) {
            case let (localHash?, cloudHash?):
                guard localHash != cloudHash else { continue }
                if localHash == baselineHash {
                    try copyReplacing(from: cloudFile, to: localFile)
                } else if cloudHash == baselineHash {
                    try copyReplacing(from: localFile, to: cloudFile)
                } else {
                    let localDate = modificationDate(of: localFile) ?? .distantPast
                    let cloudDate = modificationDate(of: cloudFile) ?? .distantPast
                    if localDate > cloudDate || (localDate == cloudDate && localHash > cloudHash) {
                        try copyReplacing(from: localFile, to: cloudFile)
                    } else {
                        try copyReplacing(from: cloudFile, to: localFile)
                    }
                }
                copied += 1
            case let (localHash?, nil):
                if localHash == baselineHash {
                    try removeItem(at: localFile)
                } else {
                    try copyReplacing(from: localFile, to: cloudFile)
                }
                copied += 1
            case let (nil, cloudHash?):
                if cloudHash == baselineHash {
                    try removeItem(at: cloudFile)
                } else {
                    try copyReplacing(from: cloudFile, to: localFile)
                }
                copied += 1
            case (nil, nil):
                continue
            }
        }

        var hashes: [String: String] = [:]
        for name in Set(fileNames(at: local) + fileNames(at: cloud)) {
            let localFile = local.appendingPathComponent(name)
            let cloudFile = cloud.appendingPathComponent(name)
            if let localHash = fileHash(at: localFile), localHash == fileHash(at: cloudFile) {
                hashes[name] = localHash
            }
        }
        let state = try JSONEncoder().encode(MediaSyncState(hashes: hashes))
        try state.write(to: stateURL, options: .atomic)
        return copied
    }

    private static func fileHash(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func removeItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var removalError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do { try FileManager.default.removeItem(at: coordinatedURL) }
            catch { removalError = error }
        }
        if let coordinationError { throw ICloudSyncError.failed(coordinationError.localizedDescription) }
        if let removalError { throw ICloudSyncError.failed(removalError.localizedDescription) }
    }

    private static func copyReplacing(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(
            readingItemAt: source,
            options: [],
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { readURL, writeURL in
            let stagingURL = writeURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).sync")
            do {
                try fm.copyItem(at: readURL, to: stagingURL)
                if fm.fileExists(atPath: writeURL.path) {
                    _ = try fm.replaceItemAt(writeURL, withItemAt: stagingURL)
                } else {
                    try fm.moveItem(at: stagingURL, to: writeURL)
                }
            } catch {
                try? fm.removeItem(at: stagingURL)
                copyError = error
            }
        }
        if let coordinationError {
            throw ICloudSyncError.failed(coordinationError.localizedDescription)
        }
        if let copyError {
            throw ICloudSyncError.failed(copyError.localizedDescription)
        }
    }

    private static func copyLocalReplacing(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).local-sync")
        do {
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func downloadIfNeeded(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadRequestedKey
        ])
        let status = values?.ubiquitousItemDownloadingStatus
        let stillDownloading = values?.ubiquitousItemIsDownloading == true
        let downloadRequested = values?.allValues[.ubiquitousItemDownloadRequestedKey] as? Bool == true
        if !stillDownloading, status == .current {
            return
        }
        if !stillDownloading, !downloadRequested {
            try fm.startDownloadingUbiquitousItem(at: url)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let latest = try? url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
                .ubiquitousItemDownloadRequestedKey
            ])
            if latest?.ubiquitousItemDownloadingStatus == .current,
               latest?.ubiquitousItemIsDownloading != true {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ICloudSyncError.failed("O iCloud ainda está baixando \(url.lastPathComponent). Tente de novo em instantes.")
    }

    private static func modificationDate(of url: URL) -> Date? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func directoryNames(at url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            let path = url.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    private static func fileNames(at url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
    }

    private static func removeSidecars(_ database: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
    }
}
