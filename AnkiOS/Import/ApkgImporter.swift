import Foundation
import CryptoKit
import SQLite3
import UniformTypeIdentifiers
import SwiftUI

extension UTType {
    static let ankiApkg = UTType(filenameExtension: "apkg") ?? .archive
    static let ankiColpkg = UTType(filenameExtension: "colpkg") ?? .archive
}

enum ImportError: Error, LocalizedError {
    case invalidPackage
    case missingCollection
    case stubCollection
    case unsupportedPackageVersion
    case incompatibleNotetypeMerge
    case unzipFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Invalid Anki package"
        case .missingCollection: return "No collection database found in package"
        case .stubCollection: return "Package requires a newer Anki format that could not be read"
        case .unsupportedPackageVersion: return "Este pacote foi criado por uma versão do Anki que ainda não é compatível."
        case .incompatibleNotetypeMerge: return "Não é possível mesclar tipos de nota Cloze e Basic."
        case .unzipFailed(let s): return "Unzip failed: \(s)"
        case .decodeFailed(let s): return s
        }
    }
}

enum PackageUpdateCondition: String, CaseIterable, Identifiable {
    case ifNewer
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ifNewer: "Se o pacote for mais recente"
        case .always: "Sempre"
        case .never: "Nunca"
        }
    }
}

@MainActor
final class ApkgImporter {
    private let store: CollectionStore
    private var mediaRenames: [String: String] = [:]
    private var includeScheduling = false
    private var includeDeckConfigs = false
    private var nextNewPosition = 1
    private var updateNotes = PackageUpdateCondition.ifNewer
    private var updateNotetypes = PackageUpdateCondition.ifNewer
    private var mergeNotetypes = false

    private struct NotetypeMergeResult {
        var json: String
        var idMap: [Int64: Int64]
        var fieldMaps: [Int64: [Int]]
        var templateMaps: [Int64: [Int: Int]]
        var existingFieldMaps: [Int64: [Int]]
        var existingTemplateMaps: [Int64: [Int: Int]]
        var changedIDs: Set<Int64>
    }

    private struct ImportIDMaps {
        var noteTypes: [Int64: Int64] = [:]
        var decks: [Int64: Int64] = [:]
        var deckConfigs: [Int64: Int64] = [:]
        var cards: [Int64: Int64] = [:]
        var noteTypeFields: [Int64: [Int]] = [:]
        var noteTypeTemplates: [Int64: [Int: Int]] = [:]
    }

    init(store: CollectionStore) {
        self.store = store
    }

    @discardableResult
    func importPackage(
        at url: URL,
        withScheduling: Bool = false,
        withDeckConfigs: Bool = false,
        mergeNotetypes: Bool = false,
        updateNotes: PackageUpdateCondition = .ifNewer,
        updateNotetypes: PackageUpdateCondition = .ifNewer
    ) async throws -> String {
        let isColpkg = url.pathExtension.lowercased() == "colpkg"
        includeScheduling = isColpkg || withScheduling
        includeDeckConfigs = isColpkg || withDeckConfigs
        self.updateNotes = updateNotes
        self.updateNotetypes = updateNotetypes
        self.mergeNotetypes = !isColpkg && mergeNotetypes
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("apkg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        try ZipArchive.unzip(url, to: temp)

        let packageFormat = try packageFormat(in: temp)
        let collectionURL = try locateCollection(in: temp, format: packageFormat)
        let modernMediaEntries = packageFormat == .latest ? try loadModernMediaEntries(in: temp) : nil
        let sourceMediaMap: [String: String]
        if let modernMediaEntries {
            try decompressModernMedia(modernMediaEntries, in: temp)
            sourceMediaMap = Dictionary(uniqueKeysWithValues: modernMediaEntries.enumerated().map { (String($0.offset), $0.element.name) })
        } else {
            sourceMediaMap = try loadLegacyMediaMap(in: temp)
        }
        let mediaMap = try store.mediaStore.resolvingImportedMedia(in: temp, mapping: sourceMediaMap)
        mediaRenames = [:]
        for (key, sourceName) in sourceMediaMap {
            if let resolvedName = mediaMap[key], sourceName != resolvedName, mediaRenames[sourceName] == nil {
                mediaRenames[sourceName] = resolvedName
            }
        }
        defer { mediaRenames = [:] }
        if isColpkg {
            let backup = try store.prepareCollectionReplacement()
            do {
                try store.db.exec("BEGIN IMMEDIATE")
                do {
                    try mergeCollection(from: collectionURL, replacing: true)
                    try store.mediaStore.copyImportedMedia(from: temp, mapping: mediaMap)
                    try store.reloadMeta()
                    try store.refreshCounts()
                    try store.db.exec("COMMIT")
                } catch {
                    try? store.db.exec("ROLLBACK")
                    try? store.reloadMeta()
                    throw error
                }
            } catch {
                try store.restoreCollectionBackup(from: backup)
                throw error
            }
        } else {
            try store.db.exec("BEGIN IMMEDIATE")
            do {
                try mergeCollection(from: collectionURL, replacing: false)
                try store.mediaStore.copyImportedMedia(from: temp, mapping: mediaMap)
                try store.db.exec("COMMIT")
            } catch {
                try? store.db.exec("ROLLBACK")
                try? store.reloadMeta()
                throw error
            }
        }
        try store.reloadMeta()
        try store.refreshCounts()
        store.notifyDeckContentAdded()
        if isColpkg {
            return "Coleção restaurada do .colpkg. A coleção anterior foi salva em Backups."
        }
        return "Pacote .apkg importado na coleção."
    }

    private func packageFormat(in folder: URL) throws -> PackageFormat {
        let metaURL = folder.appendingPathComponent("meta")
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent("collection.anki21").path)
                ? .legacy2
                : .legacy1
        }
        let metadata = ProtoMessage(data: try Data(contentsOf: metaURL))
        guard metadata.has(1) else { throw ImportError.unsupportedPackageVersion }
        return switch metadata.int(1) {
        case 1: .legacy1
        case 2: .legacy2
        case 3: .latest
        default: throw ImportError.unsupportedPackageVersion
        }
    }

    private func locateCollection(in folder: URL, format: PackageFormat) throws -> URL {
        let collection = folder.appendingPathComponent(format.collectionFilename)
        guard FileManager.default.fileExists(atPath: collection.path) else {
            throw ImportError.missingCollection
        }
        let decoded = format == .latest ? try decodeAnki21b(collection, into: folder) : collection
        if try isStubCollection(decoded) { throw ImportError.stubCollection }
        return decoded
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

    private struct ModernMediaEntry {
        var name: String
        var size: Int
        var sha1: Data
    }

    private enum PackageFormat: Equatable {
        case legacy1
        case legacy2
        case latest

        var collectionFilename: String {
            switch self {
            case .legacy1: "collection.anki2"
            case .legacy2: "collection.anki21"
            case .latest: "collection.anki21b"
            }
        }
    }

    private func loadLegacyMediaMap(in folder: URL) throws -> [String: String] {
        let mediaURL = folder.appendingPathComponent("media")
        guard FileManager.default.fileExists(atPath: mediaURL.path) else { return [:] }
        let data = try Data(contentsOf: mediaURL)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ImportError.decodeFailed("O manifesto de mídia do pacote Anki é inválido.")
        }
        var normalized: [String: String] = [:]
        for (rawIndex, filename) in obj {
            guard let index = Int(rawIndex), index >= 0 else {
                throw ImportError.decodeFailed("O manifesto de mídia contém um índice inválido.")
            }
            guard MediaStore.isValidMediaFilename(filename) else {
                throw ImportError.decodeFailed("O manifesto de mídia contém um nome de arquivo inválido.")
            }
            let key = String(index)
            guard normalized[key] == nil else {
                throw ImportError.decodeFailed("O manifesto de mídia contém índices duplicados.")
            }
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(key).path) else {
                throw ImportError.decodeFailed("O arquivo de mídia \(filename) listado no pacote está ausente.")
            }
            normalized[key] = filename
        }
        return normalized
    }

    private func loadModernMediaEntries(in folder: URL) throws -> [ModernMediaEntry] {
        let mediaURL = folder.appendingPathComponent("media")
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw ImportError.decodeFailed("O manifesto de mídia do pacote .anki21b está ausente.")
        }
        let compressedManifest = try Data(contentsOf: mediaURL)
        let manifest = try Zstd.decompressPayload(compressedManifest)
        let entries = ProtoMessage(data: manifest).messages(1)
        if !manifest.isEmpty, entries.isEmpty {
            throw ImportError.decodeFailed("O manifesto de mídia do pacote .anki21b é inválido.")
        }
        return try entries.map { entry in
            let name = entry.string(1)
            let size = entry.int(2)
            guard !name.isEmpty, size >= 0, let sha1 = entry.bytes(3), sha1.count == 20 else {
                throw ImportError.decodeFailed("O manifesto de mídia do pacote .anki21b contém uma entrada inválida.")
            }
            guard MediaStore.isValidMediaFilename(name) else {
                throw ImportError.decodeFailed("O manifesto de mídia contém um nome de arquivo inválido.")
            }
            return ModernMediaEntry(name: name, size: size, sha1: sha1)
        }
    }

    private func decompressModernMedia(_ entries: [ModernMediaEntry], in folder: URL) throws {
        for (index, entry) in entries.enumerated() {
            let mediaURL = folder.appendingPathComponent(String(index))
            guard FileManager.default.fileExists(atPath: mediaURL.path) else {
                throw ImportError.decodeFailed("O arquivo de mídia \(entry.name) listado no pacote está ausente.")
            }
            let compressed = try Data(contentsOf: mediaURL)
            let decoded = try Zstd.decompressPayload(compressed, expectedSize: entry.size)
            guard decoded.count == entry.size,
                  Data(Insecure.SHA1.hash(data: decoded)) == entry.sha1 else {
                throw ImportError.decodeFailed("O arquivo de mídia \(entry.name) está corrompido.")
            }
            try decoded.write(to: mediaURL, options: .atomic)
        }
    }

    private func mergeCollection(from url: URL, replacing: Bool) throws {
        let src = try SQLiteDatabase(path: url.path)
        let modelsJSON = try src.scalarText("SELECT models FROM col") ?? "{}"
        let decksJSON = try src.scalarText("SELECT decks FROM col") ?? "{}"
        let dconfJSON = try src.scalarText("SELECT dconf FROM col") ?? "{}"
        let tagsJSON = try src.scalarText("SELECT tags FROM col") ?? "{}"
        let confJSON = try src.scalarText("SELECT conf FROM col") ?? "{}"
        if !includeScheduling && !replacing,
           let sourceConf = try? JSONSerialization.jsonObject(with: Data(confJSON.utf8)) as? [String: Any] {
            nextNewPosition = max(1, (sourceConf["nextPos"] as? NSNumber)?.intValue ?? 1)
        }

        if modelsJSON.count > 2 {
            try mergeSchema11(src: src, modelsJSON: rewriteLegacyModelMedia(modelsJSON), decksJSON: decksJSON, dconfJSON: dconfJSON, tagsJSON: tagsJSON, confJSON: confJSON, replacing: replacing)
        } else {
            try mergeSchema18(src: src, replacing: replacing)
        }
    }

    private func mergeSchema11(src: SQLiteDatabase, modelsJSON: String, decksJSON: String, dconfJSON: String, tagsJSON: String, confJSON: String, replacing: Bool) throws {
        let dest = store.db!

        let destDecksJSON = try dest.scalarText("SELECT decks FROM col") ?? "{}"
        let destModelsJSON = try dest.scalarText("SELECT models FROM col") ?? "{}"
        let destDconfJSON = try dest.scalarText("SELECT dconf FROM col") ?? "{}"
        let destTagsJSON = try dest.scalarText("SELECT tags FROM col") ?? "{}"

        let modelMerge: NotetypeMergeResult
        if mergeNotetypes && !replacing {
            modelMerge = try mergeNotetypeSchemas(existing: destModelsJSON, incoming: modelsJSON)
        } else {
            let result = try mergeImportedNotetypes(
                existing: destModelsJSON,
                incoming: modelsJSON,
                replacing: replacing
            )
            modelMerge = result
        }
        let configMerge = includeDeckConfigs
            ? try mergeImportedDeckConfigs(existing: destDconfJSON, incoming: dconfJSON, replacing: replacing)
            : (json: destDconfJSON, idMap: try deckConfigIDMap(incoming: dconfJSON, existing: destDconfJSON))
        let deckMerge = try mergeImportedDecks(
            existing: destDecksJSON,
            incoming: decksJSON,
            referenceMap: configMerge.idMap,
            replacing: replacing,
            source: src
        )
        let modelsWithDecks = try remapModelDeckReferences(modelMerge.json, deckIDs: deckMerge.idMap)

        try dest.run("UPDATE col SET decks=?, models=?, dconf=?, tags=?", bind: { stmt in
            try SQLiteDatabase.bindText(stmt, 1, deckMerge.json)
            try SQLiteDatabase.bindText(stmt, 2, modelsWithDecks)
            try SQLiteDatabase.bindText(stmt, 3, configMerge.json)
            try SQLiteDatabase.bindText(stmt, 4, try self.mergeJSONObjects(destTagsJSON, tagsJSON))
        })

        if let importedConf = try JSONSerialization.jsonObject(with: Data(confJSON.utf8)) as? [String: Any],
           var localConf = try JSONSerialization.jsonObject(with: Data((try dest.scalarText("SELECT conf FROM col") ?? "{}").utf8)) as? [String: Any] {
            if replacing {
                for (key, value) in importedConf { localConf[key] = value }
            } else {
                for (key, value) in importedConf where localConf[key] == nil {
                    localConf[key] = value
                }
                if let fsrsEnabled = importedConf["fsrs"] {
                    localConf["fsrs"] = fsrsEnabled
                }
            }
            try store.saveConf(localConf)
        }

        var maps = ImportIDMaps()
        maps.noteTypes = modelMerge.idMap
        maps.noteTypeFields = modelMerge.fieldMaps
        maps.noteTypeTemplates = modelMerge.templateMaps
        maps.decks = deckMerge.idMap
        maps.deckConfigs = configMerge.idMap
        try migrateMergedNotetypeData(modelMerge)
        if !modelMerge.changedIDs.isEmpty {
            try store.reloadMeta()
            for id in modelMerge.changedIDs { try store.syncCardsForNotetype(mid: id) }
        }
        if mergeNotetypes { try resolveCrossNotetypeConflicts(from: src, to: dest, maps: &maps) }
        try copyNotesAndCards(from: src, to: dest, maps: &maps, withScheduling: includeScheduling, shiftCollectionRelativeDates: !replacing, updateNotes: updateNotes)
        if includeScheduling { try copyRevlog(from: src, to: dest, cardIDs: maps.cards) }
        if replacing { try restoreCollectionTiming(from: src, to: dest) }
        try store.touchCol()
    }

    private func mergeSchema18(src: SQLiteDatabase, replacing: Bool) throws {
        let dest = store.db!
        var maps = ImportIDMaps()
        let importedConf = try collectionConfig(from: src)
        if !importedConf.isEmpty,
           var localConf = try JSONSerialization.jsonObject(
            with: Data((try dest.scalarText("SELECT conf FROM col") ?? "{}").utf8)
           ) as? [String: Any] {
            if replacing {
                for (key, value) in importedConf { localConf[key] = value }
            } else {
                for (key, value) in importedConf where localConf[key] == nil {
                    localConf[key] = value
                }
                if let fsrsEnabled = importedConf["fsrs"] {
                    localConf["fsrs"] = fsrsEnabled
                }
            }
            try store.saveConf(localConf)
        }
        var hasNotetypes = false
        try? src.query("SELECT name FROM sqlite_master WHERE type='table' AND name='notetypes'") { _ in
            hasNotetypes = true
        }
        if hasNotetypes {
            var models: [String: Any] = [:]
            var fieldsByNotetype: [Int64: [[String: Any]]] = [:]
            var templatesByNotetype: [Int64: [[String: Any]]] = [:]
            try src.query("SELECT ntid, ord, name, config FROM fields ORDER BY ntid, ord") { stmt in
                let ntid = sqlite3_column_int64(stmt, 0)
                let ord = Int(sqlite3_column_int(stmt, 1))
                let config = ProtoMessage(data: SQLiteDatabase.blob(stmt, 3))
                var field: [String: Any] = [
                    "name": SQLiteDatabase.text(stmt, 2),
                    "ord": ord,
                    "sticky": config.bool(1),
                    "rtl": config.bool(2),
                    "font": config.string(3, default: "Arial"),
                    "size": config.int(4, default: 20),
                    "description": config.string(5),
                    "plainText": config.bool(6),
                    "collapsed": config.bool(7),
                    "excludeFromSearch": config.bool(8),
                    "preventDeletion": config.bool(11)
                ]
                Self.mergeProtoOther(
                    config,
                    into: &field,
                    excluding: ["name", "ord", "sticky", "rtl", "font", "size", "description", "plainText", "collapsed", "excludeFromSearch", "id", "tag", "preventDeletion"]
                )
                let fieldID = config.int64(9)
                if fieldID > 0 { field["id"] = fieldID }
                if config.has(10) { field["tag"] = config.int(10) }
                fieldsByNotetype[ntid, default: []].append(field)
            }
            try src.query("SELECT ntid, ord, name, mtime_secs, usn, config FROM templates ORDER BY ntid, ord") { stmt in
                let ntid = sqlite3_column_int64(stmt, 0)
                let ord = Int(sqlite3_column_int(stmt, 1))
                let config = ProtoMessage(data: SQLiteDatabase.blob(stmt, 5))
                var template: [String: Any] = [
                    "name": SQLiteDatabase.text(stmt, 2),
                    "ord": ord,
                    "qfmt": rewriteMediaReferences(config.string(1)),
                    "afmt": rewriteMediaReferences(config.string(2)),
                    "bqfmt": rewriteMediaReferences(config.string(3)),
                    "bafmt": rewriteMediaReferences(config.string(4)),
                    "bfont": config.string(6),
                    "bsize": config.int(7)
                ]
                Self.mergeProtoOther(
                    config,
                    into: &template,
                    excluding: ["name", "ord", "qfmt", "afmt", "bqfmt", "bafmt", "did", "bfont", "bsize", "id", "mod", "usn"]
                )
                let did = config.int64(5)
                if did > 0 { template["did"] = did }
                let templateID = config.int64(8)
                if templateID > 0 { template["id"] = templateID }
                templatesByNotetype[ntid, default: []].append(template)
            }
            try src.query("SELECT id, name, mtime_secs, usn, config FROM notetypes") { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                let name = SQLiteDatabase.text(stmt, 1)
                let now = sqlite3_column_int64(stmt, 2)
                let usn = Int(sqlite3_column_int(stmt, 3))
                let config = ProtoMessage(data: SQLiteDatabase.blob(stmt, 4))
                let reqs: [[Any]] = config.messages(8).map { requirement in
                    let rawKind = requirement.int(2)
                    let kind: Any
                    switch rawKind {
                    case 0: kind = "none"
                    case 1: kind = "any"
                    case 2: kind = "all"
                    default: kind = rawKind
                    }
                    return [requirement.int(1), kind, requirement.integers(3)]
                }
                var model: [String: Any] = [
                    "id": id,
                    "name": name,
                    "type": config.int(1),
                    "mod": now,
                    "usn": usn,
                    "sortf": config.int(2),
                    "tmpls": templatesByNotetype[id] ?? [],
                    "flds": fieldsByNotetype[id] ?? [],
                    "css": rewriteMediaReferences(config.string(3, default: AnkiNotetype.defaultCSS)),
                    "latexPre": config.string(5),
                    "latexPost": config.string(6),
                    "latexsvg": config.bool(7),
                    "req": reqs,
                    "tags": [],
                    "vers": []
                ]
                let defaultDeckID = config.int64(4)
                if defaultDeckID > 0 { model["did"] = defaultDeckID }
                Self.mergeProtoOther(
                    config,
                    into: &model,
                    excluding: ["id", "name", "type", "mod", "usn", "sortf", "did", "tmpls", "flds", "css", "latexPre", "latexPost", "latexsvg", "req", "originalStockKind", "originalId"]
                )
                let originalStockKind = config.int(9)
                if originalStockKind != 0 { model["originalStockKind"] = originalStockKind }
                model["originalId"] = id
                models[String(id)] = model
            }
            let modelsJSON = CollectionSchema.encodeJSON(models)
            let destModels = try dest.scalarText("SELECT models FROM col") ?? "{}"
            let modelMerge: NotetypeMergeResult
            if mergeNotetypes && !replacing {
                modelMerge = try mergeNotetypeSchemas(existing: destModels, incoming: modelsJSON)
            } else {
                modelMerge = try mergeImportedNotetypes(
                    existing: destModels,
                    incoming: modelsJSON,
                    replacing: replacing
                )
            }
            maps.noteTypes = modelMerge.idMap
            maps.noteTypeFields = modelMerge.fieldMaps
            maps.noteTypeTemplates = modelMerge.templateMaps
            try dest.run("UPDATE col SET models = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, modelMerge.json)
            })
            try migrateMergedNotetypeData(modelMerge)
            if !modelMerge.changedIDs.isEmpty {
                try store.reloadMeta()
                for id in modelMerge.changedIDs { try store.syncCardsForNotetype(mid: id) }
            }
            if mergeNotetypes { try resolveCrossNotetypeConflicts(from: src, to: dest, maps: &maps) }

            if try hasTable("tags", in: src) {
                var importedTags: [String: Any] = [:]
                try src.query("SELECT tag, usn FROM tags") { stmt in
                    importedTags[SQLiteDatabase.text(stmt, 0)] = Int(sqlite3_column_int(stmt, 1))
                }
                let localTags = try dest.scalarText("SELECT tags FROM col") ?? "{}"
                let mergedTags = try mergeJSONObjects(localTags, CollectionSchema.encodeJSON(importedTags))
                try dest.run("UPDATE col SET tags = ?", bind: {
                    try SQLiteDatabase.bindText($0, 1, mergedTags)
                })
            }

            var decks: [String: Any] = [:]
            try src.query("SELECT id, name, mtime_secs, usn, common, kind FROM decks") { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                let name = SQLiteDatabase.text(stmt, 1).replacingOccurrences(of: "\u{1f}", with: "::")
                let mod = sqlite3_column_int64(stmt, 2)
                let usn = Int(sqlite3_column_int(stmt, 3))
                let common = ProtoMessage(data: SQLiteDatabase.blob(stmt, 4))
                let kind = ProtoMessage(data: SQLiteDatabase.blob(stmt, 5))
                var deck: [String: Any] = [
                    "id": id, "name": name, "mod": mod, "usn": usn,
                    "collapsed": common.bool(1), "browserCollapsed": common.bool(2), "desc": "",
                    "dyn": 0, "conf": 1, "extendNew": 0, "extendRev": 0,
                    "newToday": [common.int(3), common.int(4)],
                    "revToday": [common.int(3), common.int(5)],
                    "lrnToday": [common.int(3), common.int(6)],
                    "timeToday": [common.int(3), common.int(7)]
                ]
                Self.mergeProtoOther(
                    common,
                    into: &deck,
                    excluding: ["id", "name", "mod", "usn", "collapsed", "browserCollapsed", "desc", "md", "dyn", "conf", "extendNew", "extendRev", "newToday", "revToday", "lrnToday", "timeToday", "terms", "resched", "previewDelay", "previewHard", "previewGood", "previewAgain", "desiredRetention", "newLimit", "reviewLimit", "newLimitToday", "reviewLimitToday"]
                )
                if let normal = kind.messages(1).last {
                    deck["conf"] = normal.int64(1)
                    deck["extendNew"] = normal.int(2)
                    deck["extendRev"] = normal.int(3)
                    deck["desc"] = normal.string(4)
                    deck["md"] = normal.bool(5)
                    deck["reviewLimit"] = normal.has(6) ? normal.int(6) : nil
                    deck["newLimit"] = normal.has(7) ? normal.int(7) : nil
                    if let value = normal.messages(8).last {
                        deck["reviewLimitToday"] = ["limit": value.int(1), "today": value.int(2)]
                    }
                    if let value = normal.messages(9).last {
                        deck["newLimitToday"] = ["limit": value.int(1), "today": value.int(2)]
                    }
                    if normal.has(10) {
                        deck["desiredRetention"] = normal.float(10)
                    }
                } else if let filtered = kind.messages(2).last {
                    deck["dyn"] = 1
                    deck["resched"] = filtered.bool(1)
                    deck["terms"] = filtered.messages(2).map { term in
                        [term.string(1), term.int(2), Self.filteredOrder(term.int(3))] as [Any]
                    }
                    if let first = filtered.messages(2).first {
                        deck["ankiosSearchOrder"] = Self.filteredOrder(first.int(3))
                    }
                    if let second = filtered.messages(2).dropFirst().first {
                        deck["ankiosSearchOrder2"] = Self.filteredOrder(second.int(3))
                    }
                    deck["previewDelay"] = filtered.int(4)
                    deck["previewHard"] = filtered.int(5)
                    deck["previewGood"] = filtered.int(6)
                    deck["previewAgain"] = filtered.int(7)
                }
                decks[String(id)] = deck
            }
            let decksJSON = CollectionSchema.encodeJSON(decks)

            var deckConfigs: [String: Any] = [:]
            try src.query("SELECT id, name, mtime_secs, usn, config FROM deck_config") { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                let name = SQLiteDatabase.text(stmt, 1)
                let modified = sqlite3_column_int64(stmt, 2)
                let usn = Int(sqlite3_column_int(stmt, 3))
                let config = ProtoMessage(data: SQLiteDatabase.blob(stmt, 4))
                var dconf = CollectionSchema.defaultDconf(id: id, now: modified)
                dconf["name"] = name
                dconf["usn"] = usn
                Self.mergeProtoOther(
                    config,
                    into: &dconf,
                    excluding: ["id", "name", "mod", "usn", "maxTaken", "autoplay", "timer", "stopTimerOnAnswer", "replayq", "dyn", "newMix", "newPerDayMinimum", "interdayLearningMix", "newSortOrder", "reviewOrder", "newGatherPriority", "buryInterdayLearning", "fsrsWeights", "fsrsParams5", "fsrsParams6", "desiredRetention", "historicalRetention", "ignoreRevlogsBeforeDate", "paramSearch", "secondsToShowQuestion", "secondsToShowAnswer", "questionAction", "answerAction", "waitForAudio", "easyDayPercents"]
                )
                dconf["autoplay"] = !config.bool(23, default: false)
                dconf["timer"] = config.bool(25) ? 1 : 0
                dconf["stopTimerOnAnswer"] = config.bool(38)
                dconf["replayq"] = !config.bool(26)
                dconf["newMix"] = config.int(30)
                dconf["interdayLearningMix"] = config.int(31)
                dconf["newSortOrder"] = config.int(32)
                dconf["reviewOrder"] = Self.reviewOrder(config.int(33))
                dconf["newGatherPriority"] = Self.newGatherPriority(config.int(34))
                dconf["newPerDayMinimum"] = config.int(35)
                dconf["buryInterdayLearning"] = config.bool(29)
                dconf["desiredRetention"] = config.float(37, default: 0.9)
                dconf["historicalRetention"] = config.float(40, default: 0.9)
                let paramSearch = config.string(45)
                if !paramSearch.isEmpty { dconf["paramSearch"] = paramSearch }
                dconf["secondsToShowQuestion"] = config.float(41)
                dconf["secondsToShowAnswer"] = config.float(42)
                dconf["questionAction"] = config.int(36)
                dconf["answerAction"] = config.int(43)
                dconf["waitForAudio"] = config.bool(44, default: true)
                dconf["maxTaken"] = config.int(24, default: 60)
                let fsrs4 = config.floats(3)
                let fsrs5 = config.floats(5)
                let fsrs6 = config.floats(6)
                if !fsrs4.isEmpty { dconf["fsrsWeights"] = fsrs4 }
                if !fsrs5.isEmpty { dconf["fsrsParams5"] = fsrs5 }
                if !fsrs6.isEmpty { dconf["fsrsParams6"] = fsrs6 }
                dconf["easyDayPercents"] = config.floats(4)
                dconf["ignoreRevlogsBeforeDate"] = config.string(46)
                var new = dconf["new"] as? [String: Any] ?? [:]
                new["delays"] = config.floats(1)
                new["ints"] = [config.int(18, default: 1), config.int(19, default: 4)]
                new["initialFactor"] = Int((config.float(11, default: 2.5) * 1000).rounded())
                new["perDay"] = config.int(9, default: 20)
                new["order"] = config.int(20, default: 1) == 0 ? 1 : 0
                new["bury"] = config.bool(27)
                dconf["new"] = new
                var rev = dconf["rev"] as? [String: Any] ?? [:]
                rev["perDay"] = config.int(10, default: 200)
                rev["ease4"] = config.float(12, default: 1.3)
                rev["hardFactor"] = config.float(13, default: 1.2)
                rev["ivlFct"] = config.float(15, default: 1)
                rev["maxIvl"] = config.int(16, default: 36500)
                rev["bury"] = config.bool(28)
                dconf["rev"] = rev
                var lapse = dconf["lapse"] as? [String: Any] ?? [:]
                lapse["delays"] = config.floats(2)
                lapse["mult"] = config.float(14)
                lapse["minInt"] = config.int(17, default: 1)
                lapse["leechAction"] = config.int(21)
                lapse["leechFails"] = config.int(22, default: 8)
                dconf["lapse"] = lapse
                deckConfigs[String(id)] = dconf
            }
            let dconfJSON = CollectionSchema.encodeJSON(deckConfigs)
            let destDconf = try dest.scalarText("SELECT dconf FROM col") ?? "{}"
            let configMerge = includeDeckConfigs
                ? try mergeImportedDeckConfigs(existing: destDconf, incoming: dconfJSON, replacing: replacing)
                : (json: destDconf, idMap: try deckConfigIDMap(incoming: dconfJSON, existing: destDconf))
            maps.deckConfigs = configMerge.idMap
            try dest.run("UPDATE col SET dconf = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, configMerge.json)
            })
            let destDecks = try dest.scalarText("SELECT decks FROM col") ?? "{}"
            let deckMerge = try mergeImportedDecks(
                existing: destDecks,
                incoming: decksJSON,
                referenceMap: maps.deckConfigs,
                replacing: replacing,
                source: src
            )
            maps.decks = deckMerge.idMap
            try dest.run("UPDATE col SET decks = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, deckMerge.json)
            })
            let mergedModels = try dest.scalarText("SELECT models FROM col") ?? "{}"
            let remappedModels = try remapModelDeckReferences(mergedModels, deckIDs: maps.decks)
            try dest.run("UPDATE col SET models = ?", bind: {
                try SQLiteDatabase.bindText($0, 1, remappedModels)
            })
        }
        try copyNotesAndCards(from: src, to: dest, maps: &maps, withScheduling: includeScheduling, shiftCollectionRelativeDates: !replacing, updateNotes: updateNotes)
        if includeScheduling { try copyRevlog(from: src, to: dest, cardIDs: maps.cards) }
        if replacing { try restoreCollectionTiming(from: src, to: dest) }
        try store.touchCol()
    }

    private func collectionConfig(from db: SQLiteDatabase) throws -> [String: Any] {
        if let raw = try db.scalarText("SELECT conf FROM col"),
           let conf = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
           !conf.isEmpty {
            return conf
        }
        guard try hasTable("config", in: db) else { return [:] }

        var conf: [String: Any] = [:]
        try db.query("SELECT key, val FROM config") { stmt in
            let key = SQLiteDatabase.text(stmt, 0)
            let value = SQLiteDatabase.blob(stmt, 1)
            guard !key.isEmpty,
                  let decoded = try? JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed]) else { return }
            conf[key] = decoded
        }
        return conf
    }

    private func hasTable(_ name: String, in db: SQLiteDatabase) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?") { stmt in
            try SQLiteDatabase.bindText(stmt, 1, name)
        } > 0
    }

    private static func mergeProtoOther(_ message: ProtoMessage, into object: inout [String: Any], excluding reserved: Set<String>) {
        guard let data = message.bytes(255),
              let extra = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, value) in extra where !reserved.contains(key) && object[key] == nil {
            object[key] = value
        }
        for (key, value) in extra where !reserved.contains(key) {
            guard let incoming = value as? [String: Any], var existing = object[key] as? [String: Any] else { continue }
            for (nestedKey, nestedValue) in incoming where existing[nestedKey] == nil {
                existing[nestedKey] = nestedValue
            }
            object[key] = existing
        }
    }

    private func deckConfigIDMap(incoming: String, existing: String) throws -> [Int64: Int64] {
        let imported = (try JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any]) ?? [:]
        let local = (try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]) ?? [:]
        let defaultID = local.first(where: { _, value in
            ((value as? [String: Any])?["name"] as? String)?.localizedCaseInsensitiveCompare("Default") == .orderedSame
        }).flatMap { Int64($0.key) }
            ?? local.keys.compactMap(Int64.init).min()
            ?? 1
        return Dictionary(uniqueKeysWithValues: imported.keys.compactMap { key in
            guard let sourceID = Int64(key) else { return nil }
            return (sourceID, defaultID)
        })
    }

    private func mergeImportedDeckConfigs(
        existing: String,
        incoming: String,
        replacing: Bool
    ) throws -> (json: String, idMap: [Int64: Int64]) {
        let local = (try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]) ?? [:]
        let imported = (try JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any]) ?? [:]
        var merged = replacing ? [:] : local
        var idMap: [Int64: Int64] = [:]
        for (key, rawValue) in imported {
            guard let id = Int64(key), var config = rawValue as? [String: Any] else { continue }
            config["id"] = id
            idMap[id] = id
            if replacing || merged[key] == nil {
                merged[key] = config
            }
        }
        return (CollectionSchema.encodeJSON(merged), idMap)
    }

    private func mergeImportedNotetypes(
        existing: String,
        incoming: String,
        replacing: Bool
    ) throws -> NotetypeMergeResult {
        var local = (try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]) ?? [:]
        let imported = (try JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any]) ?? [:]
        if replacing {
            var replacement: [String: Any] = [:]
            var idMap: [Int64: Int64] = [:]
            for (key, value) in imported {
                guard let id = Int64(key), var model = value as? [String: Any] else { continue }
                model["id"] = id
                model["originalId"] = id
                replacement[key] = model
                idMap[id] = id
            }
            return NotetypeMergeResult(
                json: CollectionSchema.encodeJSON(replacement),
                idMap: idMap,
                fieldMaps: [:],
                templateMaps: [:],
                existingFieldMaps: [:],
                existingTemplateMaps: [:],
                changedIDs: []
            )
        }

        var names = Set(local.values.compactMap { ($0 as? [String: Any])?["name"] as? String })
        var idMap: [Int64: Int64] = [:]
        var changedIDs = Set<Int64>()
        var nextID = max(Int64(Date().timeIntervalSince1970 * 1000), local.keys.compactMap(Int64.init).max().map { $0 + 1 } ?? 1)

        func uniqueID() -> Int64 {
            while local[String(nextID)] != nil { nextID += 1 }
            defer { nextID += 1 }
            return nextID
        }

        func uniqueName(_ original: String) -> String {
            var name = original
            while names.contains(name) { name += "+" }
            return name
        }

        for (key, value) in imported {
            guard let sourceID = Int64(key), var source = value as? [String: Any] else { continue }
            let sourceName = source["name"] as? String ?? ""
            source["id"] = sourceID
            source["originalId"] = sourceID

            if let existingModel = local[String(sourceID)] as? [String: Any] {
                if !notetypeSchemasMatch(existingModel, source) {
                    let duplicate = local.first { candidateKey, candidateValue in
                        guard let candidateID = Int64(candidateKey), candidateID != sourceID,
                              let candidate = candidateValue as? [String: Any],
                              (candidate["originalId"] as? NSNumber)?.int64Value == sourceID else { return false }
                        return notetypeSchemasMatch(candidate, source)
                    }
                    if let duplicate, let destinationID = Int64(duplicate.key) {
                        idMap[sourceID] = destinationID
                        continue
                    }

                    let destinationID = uniqueID()
                    let destinationName = uniqueName(sourceName)
                    source["id"] = destinationID
                    source["name"] = destinationName
                    local[String(destinationID)] = source
                    names.insert(destinationName)
                    idMap[sourceID] = destinationID
                    continue
                }

                let existingMod = (existingModel["mod"] as? NSNumber)?.int64Value ?? 0
                let sourceMod = (source["mod"] as? NSNumber)?.int64Value ?? 0
                if shouldUpdateNotetype(sourceMod: sourceMod, destinationMod: existingMod) {
                    local[String(sourceID)] = source
                    if let name = source["name"] as? String { names.insert(name) }
                    changedIDs.insert(sourceID)
                }
                idMap[sourceID] = sourceID
                continue
            }

            let destinationName = uniqueName(sourceName)
            source["name"] = destinationName
            local[String(sourceID)] = source
            names.insert(destinationName)
            idMap[sourceID] = sourceID
        }

        return NotetypeMergeResult(
            json: CollectionSchema.encodeJSON(local),
            idMap: idMap,
            fieldMaps: [:],
            templateMaps: [:],
            existingFieldMaps: [:],
            existingTemplateMaps: [:],
            changedIDs: changedIDs
        )
    }

    private func notetypeSchemasMatch(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        guard let leftType = (left["type"] as? NSNumber)?.intValue,
              let rightType = (right["type"] as? NSNumber)?.intValue,
              leftType == rightType else { return false }
        let leftFields = orderedSchemaItems(left["flds"] as? [[String: Any]] ?? [])
        let rightFields = orderedSchemaItems(right["flds"] as? [[String: Any]] ?? [])
        let leftTemplates = orderedSchemaItems(left["tmpls"] as? [[String: Any]] ?? [])
        let rightTemplates = orderedSchemaItems(right["tmpls"] as? [[String: Any]] ?? [])
        return schemaListsMatch(leftFields, rightFields) && schemaListsMatch(leftTemplates, rightTemplates)
    }

    private func schemaListsMatch(_ left: [[String: Any]], _ right: [[String: Any]]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { schemaItemsMatch($0.0, $0.1) }
    }

    private func shouldUpdateNotetype(sourceMod: Int64, destinationMod: Int64) -> Bool {
        switch updateNotetypes {
        case .ifNewer: sourceMod > destinationMod
        case .always: true
        case .never: false
        }
    }

    private func mergeNotetypeSchemas(existing: String, incoming: String) throws -> NotetypeMergeResult {
        var local = (try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]) ?? [:]
        let imported = (try JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any]) ?? [:]
        var localNames = Set<String>()
        for (key, value) in local {
            guard Int64(key) != nil, let name = (value as? [String: Any])?["name"] as? String else { continue }
            localNames.insert(name)
        }

        var idMap: [Int64: Int64] = [:]
        var fieldMaps: [Int64: [Int]] = [:]
        var templateMaps: [Int64: [Int: Int]] = [:]
        var existingFieldMaps: [Int64: [Int]] = [:]
        var existingTemplateMaps: [Int64: [Int: Int]] = [:]
        var changedIDs = Set<Int64>()
        for (sourceKey, rawValue) in imported {
            guard let sourceID = Int64(sourceKey), let source = rawValue as? [String: Any] else { continue }
            var name = source["name"] as? String ?? ""
            let destinationID = sourceID

            idMap[sourceID] = destinationID
            guard let existingModel = local[String(destinationID)] as? [String: Any] else {
                var added = source
                while localNames.contains(name) { name += "+" }
                added["name"] = name
                added["id"] = destinationID
                let fields = orderedSchemaItems(source["flds"] as? [[String: Any]] ?? [])
                let templates = orderedSchemaItems(source["tmpls"] as? [[String: Any]] ?? [])
                added["flds"] = fields.enumerated().map { index, item in var item = item; item["ord"] = index; return item }
                added["tmpls"] = templates.enumerated().map { index, item in var item = item; item["ord"] = index; return item }
                local[String(destinationID)] = added
                localNames.insert(name)
                fieldMaps[sourceID] = schemaIndexMap(source["flds"] as? [[String: Any]] ?? [], merged: fields)
                templateMaps[sourceID] = schemaOrdinalMap(source["tmpls"] as? [[String: Any]] ?? [], merged: templates)
                continue
            }

            guard let existingType = existingModel["type"] as? Int,
                  let incomingType = source["type"] as? Int,
                  (existingType == 1) == (incomingType == 1) else {
                throw ImportError.incompatibleNotetypeMerge
            }

            let existingMod = (existingModel["mod"] as? NSNumber)?.int64Value ?? 0
            let sourceMod = (source["mod"] as? NSNumber)?.int64Value ?? 0
            let useIncomingContent = shouldUpdateNotetype(sourceMod: sourceMod, destinationMod: existingMod)
            let oldFields = orderedSchemaItems(existingModel["flds"] as? [[String: Any]] ?? [])
            let sourceFields = orderedSchemaItems(source["flds"] as? [[String: Any]] ?? [])
            let oldTemplates = orderedSchemaItems(existingModel["tmpls"] as? [[String: Any]] ?? [])
            let sourceTemplates = orderedSchemaItems(source["tmpls"] as? [[String: Any]] ?? [])
            let mergedFields = mergeSchemaItems(base: oldFields, other: sourceFields, preferOther: useIncomingContent)
            let mergedTemplates = existingType == 1
                ? oldTemplates
                : mergeSchemaItems(base: oldTemplates, other: sourceTemplates, preferOther: useIncomingContent)

            let incomingFieldMap = schemaIndexMap(sourceFields, merged: mergedFields)
            let incomingTemplateMap = schemaOrdinalMap(sourceTemplates, merged: mergedTemplates)
            let oldFieldMap = schemaIndexMap(oldFields, merged: mergedFields)
            let oldTemplateMap = schemaOrdinalMap(oldTemplates, merged: mergedTemplates)
            fieldMaps[sourceID] = incomingFieldMap
            templateMaps[sourceID] = incomingTemplateMap
            existingFieldMaps[destinationID] = oldFieldMap
            existingTemplateMaps[destinationID] = oldTemplateMap

            var mergedModel = useIncomingContent ? source : existingModel
            mergedModel["id"] = destinationID
            mergedModel["flds"] = mergedFields.enumerated().map { index, item in var item = item; item["ord"] = index; return item }
            mergedModel["tmpls"] = mergedTemplates.enumerated().map { index, item in var item = item; item["ord"] = index; return item }
            let incomingRequirements = remapRequirements(source["req"], templateMap: incomingTemplateMap, fieldMap: incomingFieldMap)
            let existingRequirements = remapRequirements(existingModel["req"], templateMap: oldTemplateMap, fieldMap: oldFieldMap)
            let primaryRequirements = useIncomingContent ? incomingRequirements : existingRequirements
            let additionalRequirements = useIncomingContent ? existingRequirements : incomingRequirements
            var requirementsByOrdinal: [Int: [Any]] = [:]
            for requirement in primaryRequirements {
                guard let ordinal = (requirement.first as? NSNumber)?.intValue else { continue }
                requirementsByOrdinal[ordinal] = requirement
            }
            for requirement in additionalRequirements {
                guard let ordinal = (requirement.first as? NSNumber)?.intValue else { continue }
                if requirementsByOrdinal[ordinal] == nil { requirementsByOrdinal[ordinal] = requirement }
            }
            mergedModel["req"] = requirementsByOrdinal.keys.sorted().compactMap { requirementsByOrdinal[$0] }
            let selectedSortIndex = (mergedModel["sortf"] as? Int) ?? 0
            let selectedSortMap = useIncomingContent ? incomingFieldMap : oldFieldMap
            mergedModel["sortf"] = selectedSortMap.indices.contains(selectedSortIndex) ? selectedSortMap[selectedSortIndex] : 0
            if useIncomingContent { mergedModel["mod"] = sourceMod }
            local[String(destinationID)] = mergedModel
            localNames.insert(name)

            if useIncomingContent || oldFields.count != mergedFields.count || oldTemplates.count != mergedTemplates.count
                || oldFieldMap.enumerated().contains(where: { $0.offset != $0.element })
                || oldTemplateMap.contains(where: { $0.key != $0.value }) {
                changedIDs.insert(destinationID)
            }
        }

        return NotetypeMergeResult(
            json: CollectionSchema.encodeJSON(local),
            idMap: idMap,
            fieldMaps: fieldMaps,
            templateMaps: templateMaps,
            existingFieldMaps: existingFieldMaps,
            existingTemplateMaps: existingTemplateMaps,
            changedIDs: changedIDs
        )
    }

    private func orderedSchemaItems(_ items: [[String: Any]]) -> [[String: Any]] {
        items.sorted { left, right in
            let leftOrd = (left["ord"] as? NSNumber)?.intValue ?? 0
            let rightOrd = (right["ord"] as? NSNumber)?.intValue ?? 0
            return leftOrd < rightOrd
        }
    }

    private func mergeSchemaItems(
        base: [[String: Any]],
        other: [[String: Any]],
        preferOther: Bool
    ) -> [[String: Any]] {
        var merged = base
        for (index, item) in other.enumerated() {
            if let match = merged.firstIndex(where: { schemaItemsMatch($0, item) }) {
                if match != index, index < merged.count { merged.swapAt(match, index) }
                if preferOther, index < merged.count { merged[index] = item }
            } else {
                merged.insert(item, at: min(index, merged.count))
            }
        }
        return merged
    }

    private func schemaItemsMatch(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        if let leftID = (left["id"] as? NSNumber)?.int64Value,
           let rightID = (right["id"] as? NSNumber)?.int64Value {
            return leftID == rightID
        }
        guard let leftName = left["name"] as? String, let rightName = right["name"] as? String else { return false }
        return leftName == rightName
    }

    private func schemaIndexMap(_ source: [[String: Any]], merged: [[String: Any]]) -> [Int] {
        source.map { item in merged.firstIndex(where: { schemaItemsMatch($0, item) }) ?? 0 }
    }

    private func schemaOrdinalMap(_ source: [[String: Any]], merged: [[String: Any]]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (index, item) in source.enumerated() {
            let oldOrd = (item["ord"] as? NSNumber)?.intValue ?? index
            let newOrd = merged.firstIndex(where: { schemaItemsMatch($0, item) }) ?? oldOrd
            result[oldOrd] = newOrd
        }
        return result
    }

    private func remapRequirements(_ raw: Any?, templateMap: [Int: Int], fieldMap: [Int]) -> [[Any]] {
        guard let requirements = raw as? [[Any]] else { return [] }
        return requirements.compactMap { requirement in
            guard requirement.count >= 3,
                  let sourceOrdinal = (requirement[0] as? NSNumber)?.intValue else { return nil }
            let ordinal = templateMap[sourceOrdinal] ?? sourceOrdinal
            let fields = (requirement[2] as? [Any] ?? []).compactMap { rawField -> Int? in
                guard let sourceField = (rawField as? NSNumber)?.intValue,
                      fieldMap.indices.contains(sourceField) else { return nil }
                return fieldMap[sourceField]
            }
            return [ordinal, requirement[1], fields]
        }
    }

    private func migrateMergedNotetypeData(_ result: NotetypeMergeResult) throws {
        guard !result.changedIDs.isEmpty else { return }
        let db = store.db!
        let models = (try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any]) ?? [:]

        for mid in result.changedIDs {
            guard let model = models[String(mid)] as? [String: Any] else { continue }
            let fields = model["flds"] as? [[String: Any]] ?? []
            let sortField = model["sortf"] as? Int ?? 0
            let oldFieldMap = result.existingFieldMaps[mid] ?? fields.indices.map { $0 }
            var noteRows: [(id: Int64, fields: [String])] = []
            try db.query("SELECT id, flds FROM notes WHERE mid = ?") { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, mid)
            } map: { stmt in
                let raw = SQLiteDatabase.text(stmt, 1)
                noteRows.append((sqlite3_column_int64(stmt, 0), raw.components(separatedBy: "\u{1f}")))
            }

            for row in noteRows {
                var updatedFields = Array(repeating: "", count: fields.count)
                for oldIndex in row.fields.indices where oldFieldMap.indices.contains(oldIndex) {
                    let newIndex = oldFieldMap[oldIndex]
                    if updatedFields.indices.contains(newIndex) { updatedFields[newIndex] = row.fields[oldIndex] }
                }
                let firstField = updatedFields.first ?? ""
                let sortValue = store.stripHTMLPreservingMediaFilenames(updatedFields.indices.contains(sortField) ? updatedFields[sortField] : "")
                try db.run("UPDATE notes SET flds=?, sfld=?, csum=?, usn=-1 WHERE id=?") { stmt in
                    try SQLiteDatabase.bindText(stmt, 1, updatedFields.joined(separator: "\u{1f}"))
                    try SQLiteDatabase.bindText(stmt, 2, sortValue)
                    SQLiteDatabase.bindInt64(stmt, 3, self.store.fieldChecksum(firstField))
                    SQLiteDatabase.bindInt64(stmt, 4, row.id)
                }
            }

            let templateMap = result.existingTemplateMaps[mid] ?? [:]
            if !templateMap.isEmpty {
                var cards: [(id: Int64, ord: Int)] = []
                try db.query("SELECT c.id, c.ord FROM cards c JOIN notes n ON n.id = c.nid WHERE n.mid = ?") { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, mid)
                } map: { stmt in
                    cards.append((sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int(stmt, 1))))
                }
                for (index, card) in cards.enumerated() {
                    try db.run("UPDATE cards SET ord=? WHERE id=?") { stmt in
                        SQLiteDatabase.bindInt(stmt, 1, 50_000 + index)
                        SQLiteDatabase.bindInt64(stmt, 2, card.id)
                    }
                }
                for card in cards {
                    let ord = templateMap[card.ord] ?? card.ord
                    try db.run("UPDATE cards SET ord=? WHERE id=?") { stmt in
                        SQLiteDatabase.bindInt(stmt, 1, ord)
                        SQLiteDatabase.bindInt64(stmt, 2, card.id)
                    }
                }
            }
        }
    }

    private func tagsWithoutSchedulingMarkers(_ tags: String) -> String {
        let markers: Set<String> = ["marked", "leech"]
        let values = AnkiTag.split(tags).filter { !markers.contains($0) }
        return values.isEmpty ? "" : " \(values.joined(separator: " ")) "
    }

    private func resolveCrossNotetypeConflicts(
        from source: SQLiteDatabase,
        to destination: SQLiteDatabase,
        maps: inout ImportIDMaps
    ) throws {
        var conflicts: [String: (existingID: Int64, existingMID: Int64, incomingMID: Int64)] = [:]
        try source.query("SELECT guid, mid FROM notes") { stmt in
            let guid = SQLiteDatabase.text(stmt, 0)
            let sourceMID = sqlite3_column_int64(stmt, 1)
            guard let incomingMID = maps.noteTypes[sourceMID],
                  let existing = try noteRecord(forGUID: guid, in: destination),
                  existing.mid != incomingMID else { return }
            conflicts[guid] = (existing.id, existing.mid, incomingMID)
        }
        guard !conflicts.isEmpty else { return }

        var models = (try JSONSerialization.jsonObject(
            with: Data((try destination.scalarText("SELECT models FROM col") ?? "{}").utf8)
        ) as? [String: Any]) ?? [:]
        var notesByTypePair: [String: (existingMID: Int64, incomingMID: Int64, noteIDs: [Int64])] = [:]
        for conflict in conflicts.values {
            let key = "\(conflict.existingMID):\(conflict.incomingMID)"
            if notesByTypePair[key] == nil {
                notesByTypePair[key] = (conflict.existingMID, conflict.incomingMID, [])
            }
            notesByTypePair[key]?.noteIDs.append(conflict.existingID)
        }

        var changedTypes = Set<Int64>()
        for pair in notesByTypePair.values {
            guard let incomingModel = models[String(pair.incomingMID)] as? [String: Any],
                  let existingModel = models[String(pair.existingMID)] as? [String: Any] else { continue }
            guard let incomingKind = incomingModel["type"] as? Int,
                  let existingKind = existingModel["type"] as? Int,
                  (incomingKind == 1) == (existingKind == 1) else {
                throw ImportError.incompatibleNotetypeMerge
            }

            let incomingFields = orderedSchemaItems(incomingModel["flds"] as? [[String: Any]] ?? [])
            let existingFields = orderedSchemaItems(existingModel["flds"] as? [[String: Any]] ?? [])
            let incomingTemplates = orderedSchemaItems(incomingModel["tmpls"] as? [[String: Any]] ?? [])
            let existingTemplates = orderedSchemaItems(existingModel["tmpls"] as? [[String: Any]] ?? [])
            let mergedFields = mergeSchemaItems(base: incomingFields, other: existingFields, preferOther: false)
            let mergedTemplates = incomingKind == 1
                ? incomingTemplates
                : mergeSchemaItems(base: incomingTemplates, other: existingTemplates, preferOther: false)
            let incomingFieldMap = schemaIndexMap(incomingFields, merged: mergedFields)
            let existingFieldMap = schemaIndexMap(existingFields, merged: mergedFields)
            let incomingTemplateMap = schemaOrdinalMap(incomingTemplates, merged: mergedTemplates)
            let existingTemplateMap = schemaOrdinalMap(existingTemplates, merged: mergedTemplates)

            var mergedModel = incomingModel
            mergedModel["flds"] = mergedFields.enumerated().map { index, item in var item = item; item["ord"] = index; return item }
            mergedModel["tmpls"] = mergedTemplates.enumerated().map { index, item in var item = item; item["ord"] = index; return item }
            let incomingRequirements = remapRequirements(incomingModel["req"], templateMap: incomingTemplateMap, fieldMap: incomingFieldMap)
            let existingRequirements = remapRequirements(existingModel["req"], templateMap: existingTemplateMap, fieldMap: existingFieldMap)
            var requirementsByOrdinal: [Int: [Any]] = [:]
            for requirement in incomingRequirements + existingRequirements {
                guard let ordinal = (requirement.first as? NSNumber)?.intValue,
                      requirementsByOrdinal[ordinal] == nil else { continue }
                requirementsByOrdinal[ordinal] = requirement
            }
            mergedModel["req"] = requirementsByOrdinal.keys.sorted().compactMap { requirementsByOrdinal[$0] }
            let sortField = incomingModel["sortf"] as? Int ?? 0
            mergedModel["sortf"] = incomingFieldMap.indices.contains(sortField) ? incomingFieldMap[sortField] : 0
            models[String(pair.incomingMID)] = mergedModel

            if let sourceMID = maps.noteTypes.first(where: { $0.value == pair.incomingMID })?.key,
               let currentFieldMap = maps.noteTypeFields[sourceMID] {
                maps.noteTypeFields[sourceMID] = currentFieldMap.map { incomingFieldMap.indices.contains($0) ? incomingFieldMap[$0] : $0 }
            }
            if let sourceMID = maps.noteTypes.first(where: { $0.value == pair.incomingMID })?.key,
               let currentTemplateMap = maps.noteTypeTemplates[sourceMID] {
                maps.noteTypeTemplates[sourceMID] = currentTemplateMap.mapValues { incomingTemplateMap[$0] ?? $0 }
            }

            for noteID in pair.noteIDs {
                var oldFields: [String] = []
                try destination.query("SELECT flds FROM notes WHERE id = ?") { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, noteID)
                } map: { stmt in
                    oldFields = SQLiteDatabase.text(stmt, 0).components(separatedBy: "\u{1f}")
                }
                var updatedFields = Array(repeating: "", count: mergedFields.count)
                for index in oldFields.indices where existingFieldMap.indices.contains(index) {
                    let destinationIndex = existingFieldMap[index]
                    if updatedFields.indices.contains(destinationIndex) { updatedFields[destinationIndex] = oldFields[index] }
                }
                let firstField = updatedFields.first ?? ""
                let sortIndex = mergedModel["sortf"] as? Int ?? 0
                let sortValue = store.stripHTMLPreservingMediaFilenames(updatedFields.indices.contains(sortIndex) ? updatedFields[sortIndex] : "")
                try destination.run("UPDATE notes SET mid=?, flds=?, sfld=?, csum=?, usn=-1 WHERE id=?") { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, pair.incomingMID)
                    try SQLiteDatabase.bindText(stmt, 2, updatedFields.joined(separator: "\u{1f}"))
                    try SQLiteDatabase.bindText(stmt, 3, sortValue)
                    SQLiteDatabase.bindInt64(stmt, 4, self.store.fieldChecksum(firstField))
                    SQLiteDatabase.bindInt64(stmt, 5, noteID)
                }

                var cards: [(id: Int64, ord: Int)] = []
                try destination.query("SELECT id, ord FROM cards WHERE nid = ?") { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, noteID)
                } map: { stmt in
                    cards.append((sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int(stmt, 1))))
                }
                for (index, card) in cards.enumerated() {
                    try destination.run("UPDATE cards SET ord=? WHERE id=?") { stmt in
                        SQLiteDatabase.bindInt(stmt, 1, 50_000 + index)
                        SQLiteDatabase.bindInt64(stmt, 2, card.id)
                    }
                }
                for card in cards {
                    let ordinal = existingTemplateMap[card.ord] ?? card.ord
                    try destination.run("UPDATE cards SET ord=? WHERE id=?") { stmt in
                        SQLiteDatabase.bindInt(stmt, 1, ordinal)
                        SQLiteDatabase.bindInt64(stmt, 2, card.id)
                    }
                }
            }
            changedTypes.insert(pair.incomingMID)
        }

        try destination.run("UPDATE col SET models=?") {
            try SQLiteDatabase.bindText($0, 1, CollectionSchema.encodeJSON(models))
        }
        try store.reloadMeta()
        for mid in changedTypes { try store.syncCardsForNotetype(mid: mid) }
    }

    /// Merge notes/cards like Anki desktop: match existing notes by `guid`, cards by `(nid, ord)`.
    private func copyNotesAndCards(
        from src: SQLiteDatabase,
        to dest: SQLiteDatabase,
        maps: inout ImportIDMaps,
        withScheduling: Bool,
        shiftCollectionRelativeDates: Bool,
        updateNotes: PackageUpdateCondition
    ) throws {
        try store.reloadMeta()
        var nidMap: [Int64: Int64] = [:]
        var sourceNoteTypes: [Int64: Int64] = [:]
        let collectionDayDelta = withScheduling && shiftCollectionRelativeDates
            ? try collectionDayDelta(source: src)
            : 0

        try src.query("SELECT id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data FROM notes") { stmt in
            let srcID = sqlite3_column_int64(stmt, 0)
            let guid = SQLiteDatabase.text(stmt, 1)
            let sourceMID = sqlite3_column_int64(stmt, 2)
            sourceNoteTypes[srcID] = sourceMID
            let mid = maps.noteTypes[sourceMID] ?? sourceMID
            let mod = sqlite3_column_int64(stmt, 3)
            let usn = Int(sqlite3_column_int(stmt, 4))
            let sourceTags = SQLiteDatabase.text(stmt, 5)
            let tags = withScheduling ? sourceTags : tagsWithoutSchedulingMarkers(sourceTags)
            let sourceFields = rewriteMediaReferences(SQLiteDatabase.text(stmt, 6)).components(separatedBy: "\u{1f}")
            let fieldMap = maps.noteTypeFields[sourceMID]
            let flds: String
            let sfld: String
            if let fieldMap {
                var reordered = Array(repeating: "", count: fieldMap.count)
                for sourceIndex in sourceFields.indices where fieldMap.indices.contains(sourceIndex) {
                    let destinationIndex = fieldMap[sourceIndex]
                    if reordered.indices.contains(destinationIndex) { reordered[destinationIndex] = sourceFields[sourceIndex] }
                }
                flds = reordered.joined(separator: "\u{1f}")
                let sortIndex = store.notetype(id: mid)?.sortf ?? 0
                sfld = store.stripHTMLPreservingMediaFilenames(reordered.indices.contains(sortIndex) ? reordered[sortIndex] : "")
            } else {
                flds = sourceFields.joined(separator: "\u{1f}")
                sfld = SQLiteDatabase.text(stmt, 7)
            }
            var csum = sqlite3_column_int64(stmt, 8)
            if fieldMap != nil { csum = store.fieldChecksum(flds.components(separatedBy: "\u{1f}").first ?? "") }
            let flags = Int(sqlite3_column_int(stmt, 9))
            let data = SQLiteDatabase.text(stmt, 10)

            if let existing = try noteRecord(forGUID: guid, in: dest) {
                if existing.mid == mid {
                    if shouldUpdate(updateNotes, sourceMod: mod, destinationMod: existing.mod) {
                        try dest.run("""
                            UPDATE notes SET mod=?, usn=?, tags=?, flds=?, sfld=?, csum=?, flags=?, data=? WHERE id=?
                        """) { b in
                            SQLiteDatabase.bindInt64(b, 1, mod)
                            SQLiteDatabase.bindInt(b, 2, usn)
                            try SQLiteDatabase.bindText(b, 3, tags)
                            try SQLiteDatabase.bindText(b, 4, flds)
                            try SQLiteDatabase.bindText(b, 5, sfld)
                            SQLiteDatabase.bindInt64(b, 6, csum)
                            SQLiteDatabase.bindInt(b, 7, flags)
                            try SQLiteDatabase.bindText(b, 8, data)
                            SQLiteDatabase.bindInt64(b, 9, existing.id)
                        }
                    }
                    nidMap[srcID] = existing.id
                }
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
            let sourceDID = sqlite3_column_int64(stmt, 2)
            let did = maps.decks[sourceDID] ?? sourceDID
            let sourceOrd = Int(sqlite3_column_int(stmt, 3))
            let sourceMID = sourceNoteTypes[srcNID] ?? 0
            let ord = maps.noteTypeTemplates[sourceMID]?[sourceOrd] ?? sourceOrd
            let mod = sqlite3_column_int64(stmt, 4)
            let usn = Int(sqlite3_column_int(stmt, 5))
            let type = Int(sqlite3_column_int(stmt, 6))
            let queue = Int(sqlite3_column_int(stmt, 7))
            var due = Int(sqlite3_column_int(stmt, 8))
            let ivl = Int(sqlite3_column_int(stmt, 9))
            let factor = Int(sqlite3_column_int(stmt, 10))
            let reps = Int(sqlite3_column_int(stmt, 11))
            let lapses = Int(sqlite3_column_int(stmt, 12))
            let left = Int(sqlite3_column_int(stmt, 13))
            var odue = Int(sqlite3_column_int(stmt, 14))
            let sourceODID = sqlite3_column_int64(stmt, 15)
            let odid = maps.decks[sourceODID] ?? sourceODID
            let flags = Int(sqlite3_column_int(stmt, 16))
            let data = SQLiteDatabase.text(stmt, 17)

            if collectionDayDelta != 0 {
                if queue == 2 || queue == 3 || type == 2 { due -= collectionDayDelta }
                if type == 2 && odue != 0 { odue -= collectionDayDelta }
            }

            guard let destNID = nidMap[srcNID] else { return }

            if try cardRecord(nid: destNID, ord: ord, in: dest) != nil {
                return
            } else {
                var destCID = srcCID
                if try rowExists(in: dest, table: "cards", id: destCID) {
                    destCID = try allocateRowID(in: dest, table: "cards")
                }
                let importedType = withScheduling ? type : 0
                let importedQueue = withScheduling ? queue : 0
                let importedDue = withScheduling
                    ? due
                    : (type == 0 ? due : nextNewPosition)
                let importedInterval = withScheduling ? ivl : 0
                let importedFactor = withScheduling ? factor : 0
                let importedReps = withScheduling ? reps : 0
                let importedLapses = withScheduling ? lapses : 0
                let importedLeft = left
                let importedOriginalDue = withScheduling ? odue : 0
                let importedOriginalDeck = withScheduling ? odid : 0
                let importedFlags = withScheduling ? flags : 0
                let importedData = data
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
                    SQLiteDatabase.bindInt(b, 7, importedType)
                    SQLiteDatabase.bindInt(b, 8, importedQueue)
                    SQLiteDatabase.bindInt(b, 9, importedDue)
                    SQLiteDatabase.bindInt(b, 10, importedInterval)
                    SQLiteDatabase.bindInt(b, 11, importedFactor)
                    SQLiteDatabase.bindInt(b, 12, importedReps)
                    SQLiteDatabase.bindInt(b, 13, importedLapses)
                    SQLiteDatabase.bindInt(b, 14, importedLeft)
                    SQLiteDatabase.bindInt(b, 15, importedOriginalDue)
                    SQLiteDatabase.bindInt64(b, 16, importedOriginalDeck)
                    SQLiteDatabase.bindInt(b, 17, importedFlags)
                    try SQLiteDatabase.bindText(b, 18, importedData)
                }
                if !withScheduling && type != 0 { nextNewPosition += 1 }
                maps.cards[srcCID] = destCID
            }
        }
    }

    private func collectionDayDelta(source: SQLiteDatabase) throws -> Int {
        let sourceCreation = try source.scalarInt64("SELECT crt FROM col")
        let sourceConfJSON = try source.scalarText("SELECT conf FROM col") ?? "{}"
        let sourceConf = (try? JSONSerialization.jsonObject(with: Data(sourceConfJSON.utf8))) as? [String: Any] ?? [:]
        let now = Date()
        let sourceToday = store.schedDay(creation: sourceCreation, configuration: sourceConf, at: now)
        return sourceToday - store.schedDay(at: now)
    }

    private func noteRecord(forGUID guid: String, in db: SQLiteDatabase) throws -> (id: Int64, mid: Int64, mod: Int64)? {
        var record: (id: Int64, mid: Int64, mod: Int64)?
        try db.query("SELECT id, mid, mod FROM notes WHERE guid = ? LIMIT 1") { stmt in
            try SQLiteDatabase.bindText(stmt, 1, guid)
        } map: { stmt in
            record = (
                sqlite3_column_int64(stmt, 0),
                sqlite3_column_int64(stmt, 1),
                sqlite3_column_int64(stmt, 2)
            )
        }
        return record
    }

    private func cardRecord(nid: Int64, ord: Int, in db: SQLiteDatabase) throws -> (id: Int64, mod: Int64)? {
        var record: (id: Int64, mod: Int64)?
        try db.query("SELECT id, mod FROM cards WHERE nid = ? AND ord = ? LIMIT 1") { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, nid)
            SQLiteDatabase.bindInt(stmt, 2, ord)
        } map: { stmt in
            record = (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
        }
        return record
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

    private func copyRevlog(from src: SQLiteDatabase, to dest: SQLiteDatabase, cardIDs: [Int64: Int64]) throws {
        try src.query("SELECT id, cid, usn, ease, ivl, lastIvl, factor, time, type FROM revlog") { stmt in
            let sourceID = sqlite3_column_int64(stmt, 0)
            let sourceCID = sqlite3_column_int64(stmt, 1)
            guard let destinationCID = cardIDs[sourceCID] else { return }
            let usn = Int(sqlite3_column_int(stmt, 2))
            let ease = Int(sqlite3_column_int(stmt, 3))
            let interval = Int(sqlite3_column_int(stmt, 4))
            let lastInterval = Int(sqlite3_column_int(stmt, 5))
            let factor = Int(sqlite3_column_int(stmt, 6))
            let time = Int(sqlite3_column_int(stmt, 7))
            let type = Int(sqlite3_column_int(stmt, 8))
            var duplicate = false
            try dest.query("""
                SELECT 1 FROM revlog
                WHERE cid = ? AND ease = ? AND ivl = ? AND lastIvl = ?
                    AND factor = ? AND time = ? AND type = ?
                    AND id BETWEEN ? AND ?
                ORDER BY ABS(id - ?) LIMIT 1
            """, bind: { statement in
                SQLiteDatabase.bindInt64(statement, 1, destinationCID)
                SQLiteDatabase.bindInt(statement, 2, ease)
                SQLiteDatabase.bindInt(statement, 3, interval)
                SQLiteDatabase.bindInt(statement, 4, lastInterval)
                SQLiteDatabase.bindInt(statement, 5, factor)
                SQLiteDatabase.bindInt(statement, 6, time)
                SQLiteDatabase.bindInt(statement, 7, type)
                SQLiteDatabase.bindInt64(statement, 8, max(sourceID - 1000, 0))
                SQLiteDatabase.bindInt64(statement, 9, sourceID + 1000)
                SQLiteDatabase.bindInt64(statement, 10, sourceID)
            }) { _ in
                duplicate = true
            }
            if duplicate { return }
            var destinationID = sourceID
            if try rowExists(in: dest, table: "revlog", id: destinationID) {
                destinationID += 1
                while try rowExists(in: dest, table: "revlog", id: destinationID) {
                    destinationID += 1
                }
            }
            try dest.run("""
                INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { b in
                SQLiteDatabase.bindInt64(b, 1, destinationID)
                SQLiteDatabase.bindInt64(b, 2, destinationCID)
                SQLiteDatabase.bindInt(b, 3, usn)
                SQLiteDatabase.bindInt(b, 4, ease)
                SQLiteDatabase.bindInt(b, 5, interval)
                SQLiteDatabase.bindInt(b, 6, lastInterval)
                SQLiteDatabase.bindInt(b, 7, factor)
                SQLiteDatabase.bindInt(b, 8, time)
                SQLiteDatabase.bindInt(b, 9, type)
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

    private func mergeImportedDecks(
        existing: String,
        incoming: String,
        referenceMap: [Int64: Int64],
        replacing: Bool,
        source: SQLiteDatabase
    ) throws -> (json: String, idMap: [Int64: Int64]) {
        var merged = (try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]) ?? [:]
        let imported = (try JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any]) ?? [:]
        let sourceDay = try sourceCollectionDay(source)
        let targetDay = replacing ? sourceDay : store.schedDay()
        let uniqueSuffix = String(Int64(Date().timeIntervalSince1970))
        var existingByName: [String: Int64] = [:]
        for (key, value) in merged {
            guard let id = Int64(key), let object = value as? [String: Any], let name = object["name"] as? String else { continue }
            existingByName[deckNameKey(name)] = id
        }

        var nextID = max(Int64(Date().timeIntervalSince1970 * 1000), merged.keys.compactMap(Int64.init).max().map { $0 + 1 } ?? 1)
        var idMap: [Int64: Int64] = [:]
        var renamedParents: [(String, String)] = []
        let decks = imported.compactMap { key, value -> (Int64, [String: Any])? in
            guard let id = Int64(key), let object = value as? [String: Any] else { return nil }
            return (id, object)
        }.sorted {
            let leftName = $0.1["name"] as? String ?? ""
            let rightName = $1.1["name"] as? String ?? ""
            let leftDepth = leftName.components(separatedBy: "::").count
            let rightDepth = rightName.components(separatedBy: "::").count
            if leftDepth == rightDepth { return $0.0 < $1.0 }
            return leftDepth < rightDepth
        }

        func reparentedName(_ rawName: String) -> String {
            for (oldPrefix, newPrefix) in renamedParents where rawName.hasPrefix(oldPrefix) {
                return newPrefix + rawName.dropFirst(oldPrefix.count)
            }
            return rawName
        }

        func uniqueID() -> Int64 {
            while merged[String(nextID)] != nil { nextID += 1 }
            defer { nextID += 1 }
            return nextID
        }

        func addNormalParent(_ name: String) -> Int64 {
            let id = uniqueID()
            let now = Int64(Date().timeIntervalSince1970)
            merged[String(id)] = [
                "id": id,
                "name": name,
                "mod": now,
                "usn": -1,
                "collapsed": false,
                "browserCollapsed": false,
                "desc": "",
                "dyn": 0,
                "conf": 1,
                "extendNew": 0,
                "extendRev": 0,
                "newToday": [targetDay, 0],
                "revToday": [targetDay, 0],
                "lrnToday": [targetDay, 0],
                "timeToday": [targetDay, 0]
            ]
            existingByName[deckNameKey(name)] = id
            return id
        }

        func uniqueDeckName(_ name: String) -> String {
            "\(name) \(uniqueSuffix)"
        }

        for (sourceID, sourceObject) in decks {
            var object = sourceObject
            let rawName = normalizedDeckName(sourceObject["name"] as? String ?? "")
            var name = reparentedName(rawName)
            object["name"] = name
            if let sourceConfig = (object["conf"] as? NSNumber)?.int64Value,
               let destinationConfig = referenceMap[sourceConfig] {
                object["conf"] = destinationConfig
            }
            correctDeckDayLimits(&object, sourceDay: sourceDay, targetDay: targetDay)

            let lookupKey = deckNameKey(name)
            if let matching = existingByName[lookupKey],
               let oldObject = merged[String(matching)] as? [String: Any] {
                let sameKind = isFilteredDeck(oldObject) == isFilteredDeck(object)
                if sameKind {
                    var updated = object
                    if !replacing {
                        updated = oldObject
                        if isFilteredDeck(object) {
                            updated = object
                        } else {
                            let description = object["desc"] as? String ?? ""
                            if !description.isEmpty {
                                updated["desc"] = description
                                updated["md"] = object["md"] ?? false
                            }
                            if let configID = (object["conf"] as? NSNumber)?.int64Value, configID != 1 {
                                updated["conf"] = configID
                            }
                            for key in ["newLimit", "reviewLimit", "newLimitToday", "reviewLimitToday"] {
                                if let value = object[key] { updated[key] = value }
                            }
                            updated["mod"] = Int64(Date().timeIntervalSince1970)
                            updated["usn"] = -1
                        }
                    }
                    updated["id"] = matching
                    updated["name"] = replacing ? name : (oldObject["name"] ?? name)
                    merged[String(matching)] = updated
                    idMap[sourceID] = matching
                    continue
                }

                let newName = uniqueDeckName(name)
                renamedParents.append((name + "::", newName + "::"))
                name = newName
                object["name"] = name
            }

            if !replacing {
                let components = name.components(separatedBy: "::")
                if components.count > 1 {
                    for depth in (1..<components.count).reversed() {
                        let parentName = components.prefix(depth).joined(separator: "::")
                        guard let parentID = existingByName[deckNameKey(parentName)],
                              let parent = merged[String(parentID)] as? [String: Any] else { continue }
                        if isFilteredDeck(parent) {
                            let newParentName = uniqueDeckName(parentName)
                            _ = addNormalParent(newParentName)
                            renamedParents.append((parentName + "::", newParentName + "::"))
                            name = reparentedName(name)
                            object["name"] = name
                        }
                        break
                    }
                }
            }

            let destinationID: Int64
            if let matching = existingByName[deckNameKey(name)] {
                destinationID = matching
            } else if merged[String(sourceID)] == nil {
                destinationID = sourceID
            } else {
                destinationID = uniqueID()
            }
            object["id"] = destinationID
            object["name"] = name
            merged[String(destinationID)] = object
            existingByName[deckNameKey(name)] = destinationID
            idMap[sourceID] = destinationID
        }

        return (CollectionSchema.encodeJSON(merged), idMap)
    }

    private func sourceCollectionDay(_ source: SQLiteDatabase) throws -> Int {
        let creation = try source.scalarInt64("SELECT crt FROM col")
        return store.schedDay(creation: creation, configuration: try collectionConfig(from: source), at: Date())
    }

    private func deckNameKey(_ name: String) -> String {
        name.lowercased()
    }

    private func normalizedDeckName(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{1f}", with: "::")
            .components(separatedBy: "::")
            .map { component in
                let scalars = component.unicodeScalars.filter { $0.value > 31 && $0.value != 127 }
                let normalized = String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
                let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                return trimmed.isEmpty ? "blank" : trimmed
            }
            .joined(separator: "::")
    }

    private func isFilteredDeck(_ deck: [String: Any]) -> Bool {
        ((deck["dyn"] as? NSNumber)?.intValue ?? 0) != 0
    }

    private func correctDeckDayLimits(_ deck: inout [String: Any], sourceDay: Int, targetDay: Int) {
        for key in ["newLimitToday", "reviewLimitToday"] {
            guard var limit = deck[key] as? [String: Any],
                  let day = (limit["today"] as? NSNumber)?.intValue else { continue }
            if day == sourceDay {
                limit["today"] = targetDay
                deck[key] = limit
            } else if targetDay > 0 {
                limit["today"] = min(day, targetDay - 1)
                deck[key] = limit
            } else {
                deck.removeValue(forKey: key)
            }
        }
    }

    private func restoreCollectionTiming(from source: SQLiteDatabase, to destination: SQLiteDatabase) throws {
        for column in ["crt", "scm", "dty", "ls"] {
            let value = try source.scalarInt64("SELECT \(column) FROM col")
            try destination.run("UPDATE col SET \(column)=?") { statement in
                SQLiteDatabase.bindInt64(statement, 1, value)
            }
        }
    }

    private func mergeNamedJSONObjects(
        existing: String,
        incoming: String,
        referenceMap: [Int64: Int64] = [:],
        referenceKey: String? = nil,
        replacing: Bool = false,
        updateCondition: PackageUpdateCondition = .ifNewer
    ) throws -> (json: String, idMap: [Int64: Int64]) {
        var merged = (try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]) ?? [:]
        let imported = (try JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any]) ?? [:]
        var existingByName: [String: Int64] = [:]
        for (key, value) in merged {
            guard let id = Int64(key), let object = value as? [String: Any], let name = object["name"] as? String else { continue }
            existingByName[name] = id
        }
        var idMap: [Int64: Int64] = [:]
        var nextID = max(Int64(Date().timeIntervalSince1970 * 1000), merged.keys.compactMap(Int64.init).max().map { $0 + 1 } ?? 1)
        for (key, rawValue) in imported {
            guard let sourceID = Int64(key), var object = rawValue as? [String: Any] else { continue }
            let name = object["name"] as? String ?? ""
            let destinationID: Int64
            if let matching = existingByName[name] {
                destinationID = matching
                let oldObject = merged[String(matching)] as? [String: Any] ?? [:]
                let oldMod = (oldObject["mod"] as? NSNumber)?.int64Value ?? 0
                let newMod = (object["mod"] as? NSNumber)?.int64Value ?? 0
                if !replacing && !shouldUpdate(updateCondition, sourceMod: newMod, destinationMod: oldMod) {
                    idMap[sourceID] = destinationID
                    continue
                }
            } else if merged[key] == nil {
                destinationID = sourceID
            } else {
                while merged[String(nextID)] != nil { nextID += 1 }
                destinationID = nextID
                nextID += 1
            }
            idMap[sourceID] = destinationID
            object["id"] = destinationID
            if let referenceKey,
               let sourceReference = (object[referenceKey] as? NSNumber)?.int64Value,
               let destinationReference = referenceMap[sourceReference] {
                object[referenceKey] = destinationReference
            }
            merged[String(destinationID)] = object
            existingByName[name] = destinationID
        }
        return (CollectionSchema.encodeJSON(merged), idMap)
    }

    private func shouldUpdate(
        _ condition: PackageUpdateCondition,
        sourceMod: Int64,
        destinationMod: Int64
    ) -> Bool {
        switch condition {
        case .ifNewer: sourceMod > destinationMod
        case .always: sourceMod != destinationMod
        case .never: false
        }
    }

    private func remapModelDeckReferences(_ json: String, deckIDs: [Int64: Int64]) throws -> String {
        guard !deckIDs.isEmpty else { return json }
        var models = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        for (key, rawModel) in models {
            guard var model = rawModel as? [String: Any] else { continue }
            if let deckID = (model["did"] as? NSNumber)?.int64Value, let mappedID = deckIDs[deckID] {
                model["did"] = mappedID
            }
            if let rawTemplates = model["tmpls"] as? [[String: Any]] {
                model["tmpls"] = rawTemplates.map { rawTemplate in
                    var template = rawTemplate
                    if let deckID = (template["did"] as? NSNumber)?.int64Value, let mappedID = deckIDs[deckID] {
                        template["did"] = mappedID
                    }
                    return template
                }
            }
            models[key] = model
        }
        return CollectionSchema.encodeJSON(models)
    }

    private func rewriteLegacyModelMedia(_ json: String) throws -> String {
        guard !mediaRenames.isEmpty else { return json }
        var models = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        for (key, rawModel) in models {
            guard var model = rawModel as? [String: Any] else { continue }
            if let css = model["css"] as? String {
                model["css"] = rewriteMediaReferences(css)
            }
            if let rawTemplates = model["tmpls"] as? [[String: Any]] {
                model["tmpls"] = rawTemplates.map { rawTemplate in
                    var template = rawTemplate
                    for key in ["qfmt", "afmt", "bqfmt", "bafmt"] {
                        if let value = template[key] as? String {
                            template[key] = rewriteMediaReferences(value)
                        }
                    }
                    return template
                }
            }
            models[key] = model
        }
        return CollectionSchema.encodeJSON(models)
    }

    private func rewriteMediaReferences(_ input: String) -> String {
        guard !mediaRenames.isEmpty else { return input }
        var output = input
        for (source, destination) in mediaRenames {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            let patterns = [
                #"\[sound:(\#(escaped))\]"#,
                #"((?:src|href|poster|data-file)\s*=\s*[\"'])(\#(escaped))([\"'])"#,
                #"(url\(\s*[\"']?)(\#(escaped))([\"']?\s*\))"#
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed()
                for match in matches {
                    guard let range = Range(match.range(at: pattern == patterns[0] ? 1 : 2), in: output) else { continue }
                    output.replaceSubrange(range, with: destination)
                }
            }
        }
        return output
    }

    private static func filteredOrder(_ value: Int) -> String {
        switch value {
        case 0: return "oldest"
        case 1: return "random"
        case 2: return "ivl"
        case 3: return "ivlDesc"
        case 4: return "lapses"
        case 5: return "added"
        case 6: return "due"
        case 7: return "latest"
        case 8: return "retrievability"
        case 9: return "retrievabilityDesc"
        case 10: return "relative"
        default: return "due"
        }
    }

    private static func reviewOrder(_ value: Int) -> Int {
        value
    }

    private static func newGatherPriority(_ value: Int) -> Int {
        value
    }
}

struct ApkgImportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var withScheduling = false
    @State private var withDeckConfigs = false
    @State private var mergeNotetypes = false
    @State private var updateNotes = PackageUpdateCondition.ifNewer
    @State private var updateNotetypes = PackageUpdateCondition.ifNewer
    let onImport: (Bool, Bool, Bool, PackageUpdateCondition, PackageUpdateCondition) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassCard(cornerRadius: 22) {
                    GlassFormSection(title: "Opções de importação") {
                    Toggle("Importar progresso de estudo", isOn: $withScheduling)
                    Text("Inclui intervalos, histórico, cartões marcados e suspensões. Desativado, os cartões novos entram como novos e o progresso local existente é mantido.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Toggle("Importar predefinições de baralho", isOn: $withDeckConfigs)
                    Text("Quando desativado, os baralhos importados usam a predefinição padrão desta coleção.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Toggle("Mesclar tipos de nota", isOn: $mergeNotetypes)
                    Text("Une campos e templates equivalentes. As opções de atualização controlam notas e modelos; o progresso do pacote substitui o agendamento local somente quando ativado acima.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    DisclosureGroup("Atualizações") {
                        Picker("Notas existentes", selection: $updateNotes) {
                            ForEach(PackageUpdateCondition.allCases) { condition in
                                Text(condition.title).tag(condition)
                            }
                        }
                        .pickerStyle(.menu)
                        Picker("Tipos de nota existentes", selection: $updateNotetypes) {
                            ForEach(PackageUpdateCondition.allCases) { condition in
                                Text(condition.title).tag(condition)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    }
                    .tint(AppTheme.accent)
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle("Importar pacote")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importar") {
                        onImport(withScheduling, withDeckConfigs, mergeNotetypes, updateNotes, updateNotetypes)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}

private struct ProtoMessage {
    private enum Value {
        case integer(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    private var fields: [Int: [Value]] = [:]

    init(data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count, let key = Self.readVarint(bytes, &offset) {
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            guard number > 0 else { break }
            switch wire {
            case 0:
                guard let value = Self.readVarint(bytes, &offset) else { return }
                fields[number, default: []].append(.integer(value))
            case 1:
                guard offset + 8 <= bytes.count else { return }
                offset += 8
            case 2:
                guard let length = Self.readVarint(bytes, &offset), length <= UInt64(bytes.count - offset) else { return }
                let end = offset + Int(length)
                fields[number, default: []].append(.bytes(Data(bytes[offset..<end])))
                offset = end
            case 5:
                guard offset + 4 <= bytes.count else { return }
                let value = UInt32(bytes[offset])
                    | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16
                    | UInt32(bytes[offset + 3]) << 24
                fields[number, default: []].append(.fixed32(value))
                offset += 4
            default:
                return
            }
        }
    }

    func int(_ number: Int, default fallback: Int = 0) -> Int {
        guard case let .integer(value)? = fields[number]?.last else { return fallback }
        return Int(value)
    }

    func has(_ number: Int) -> Bool {
        fields[number] != nil
    }

    func int64(_ number: Int) -> Int64 {
        guard case let .integer(value)? = fields[number]?.last else { return 0 }
        return Int64(bitPattern: value)
    }

    func bool(_ number: Int) -> Bool {
        int(number) != 0
    }

    func bool(_ number: Int, default fallback: Bool) -> Bool {
        guard fields[number] != nil else { return fallback }
        return bool(number)
    }

    func float(_ number: Int, default fallback: Double = 0) -> Double {
        guard case let .fixed32(bits)? = fields[number]?.last else { return fallback }
        return Double(Float(bitPattern: bits))
    }

    func floats(_ number: Int) -> [Double] {
        (fields[number] ?? []).flatMap { value -> [Double] in
            switch value {
            case let .fixed32(bits):
                return [Double(Float(bitPattern: bits))]
            case let .bytes(data):
                let bytes = [UInt8](data)
                guard bytes.count % 4 == 0 else { return [] }
                return stride(from: 0, to: bytes.count, by: 4).map { offset in
                    let bits = UInt32(bytes[offset])
                        | UInt32(bytes[offset + 1]) << 8
                        | UInt32(bytes[offset + 2]) << 16
                        | UInt32(bytes[offset + 3]) << 24
                    return Double(Float(bitPattern: bits))
                }
            case .integer:
                return []
            }
        }
    }

    func string(_ number: Int, default fallback: String = "") -> String {
        guard case let .bytes(value)? = fields[number]?.last,
              let string = String(data: value, encoding: .utf8) else { return fallback }
        return string
    }

    func bytes(_ number: Int) -> Data? {
        guard case let .bytes(value)? = fields[number]?.last else { return nil }
        return value
    }

    func integers(_ number: Int) -> [Int] {
        (fields[number] ?? []).flatMap { value -> [Int] in
            switch value {
            case let .integer(raw):
                return [Int(raw)]
            case let .bytes(data):
                let bytes = [UInt8](data)
                var offset = 0
                var result: [Int] = []
                while offset < bytes.count, let raw = Self.readVarint(bytes, &offset) {
                    result.append(Int(raw))
                }
                return result
            case .fixed32:
                return []
            }
        }
    }

    func messages(_ number: Int) -> [ProtoMessage] {
        (fields[number] ?? []).compactMap { value in
            guard case let .bytes(data) = value else { return nil }
            return ProtoMessage(data: data)
        }
    }

    func message(_ number: Int) -> ProtoMessage {
        messages(number).last ?? ProtoMessage(data: Data())
    }

    private static func readVarint(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
