import Foundation
import SQLite3

/// Command-line driver that exercises the app's core code against a collection
/// located at `$ANKIOS_PROFILES_ROOT/User 1/collection.anki2` and prints JSON,
/// so results can be diffed with the official Anki library (see oracle.py).
@MainActor
enum ParityHarness {
    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            FileHandle.standardError.write(Data("usage: ankios-harness <timing|counts|states|answer|grade-now|session|retention|stats|import|export|backup|csv-import|csv-export|filtered-rebuild|cardgen-actions|deck-actions|delete-actions|empty-actions|notetype-schema-actions|queue-actions|sync-actions|tag-actions|notetype-actions|notetype-delete-actions|latex-extract|latex-generate|template-render|search> ...\n".utf8))
            return 2
        }
        let store = CollectionStore.shared
        store.activeProfile = "User 1"
        do {
            try store.openOrCreate()
            try store.reloadMeta()
            try store.unburySiblingCardsIfNewDay()
            try store.refreshCounts()
            let output: Any
            switch command {
            case "timing": output = timing(store)
            case "counts": output = counts(store)
            case "states": output = try states(store, ids: args.dropFirst().compactMap { Int64($0) })
            case "answer": output = try answer(store, args: Array(args.dropFirst()))
            case "grade-now": output = try gradeNow(store, args: Array(args.dropFirst()))
            case "session": output = try session(store, args: Array(args.dropFirst()))
            case "retention": output = try retention(store)
            case "stats": output = try stats(store)
            case "import": output = try await importPackage(store, args: Array(args.dropFirst()))
            case "export": output = try exportPackage(store, args: Array(args.dropFirst()))
            case "backup": output = try backup(store)
            case "csv-import": output = try csvImport(store, args: Array(args.dropFirst()))
            case "csv-export": output = try csvExport(store, args: Array(args.dropFirst()))
            case "filtered-rebuild": output = try filteredRebuild(store, args: Array(args.dropFirst()))
            case "cardgen-actions": output = try cardgenActions(store)
            case "deck-actions": output = try deckActions(store, args: Array(args.dropFirst()))
            case "delete-actions": output = try deleteActions(store)
            case "empty-actions": output = try emptyActions(store)
            case "notetype-schema-actions": output = try notetypeSchemaActions(store)
            case "queue-actions": output = try queueActions(store, args: Array(args.dropFirst()))
            case "sync-actions": output = try syncActions(store, args: Array(args.dropFirst()))
            case "tag-actions": output = try tagActions(store, args: Array(args.dropFirst()))
            case "notetype-actions": output = try notetypeActions(store, args: Array(args.dropFirst()))
            case "notetype-delete-actions": output = try notetypeDeleteActions(store)
            case "latex-extract": output = try latexExtract(args: Array(args.dropFirst()))
            case "latex-generate": output = try latexGenerate(args: Array(args.dropFirst()))
            case "template-render": output = try templateRender(args: Array(args.dropFirst()))
            case "template-render-batch": output = try templateRenderBatch(args: Array(args.dropFirst()))
            case "card-render-batch": output = try cardRenderBatch(store, args: Array(args.dropFirst()))
            case "cloze-render-batch": output = try cardRenderBatch(store, args: Array(args.dropFirst()), modelName: "Cloze")
            case "search": output = try search(store, args: Array(args.dropFirst()))
            case "search-batch": output = try searchBatch(store, args: Array(args.dropFirst()))
            default:
                FileHandle.standardError.write(Data("unknown command \(command)\n".utf8))
                return 2
            }
            print(json(output))
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    static func importPackage(_ store: CollectionStore, args: [String]) async throws -> [String: Any] {
        guard let path = args.first, !path.isEmpty else {
            throw SQLiteError.exec("import <package.apkg>")
        }
        let flags = Set(args.dropFirst())
        let updateNotes = args.first(where: { $0.hasPrefix("--update-notes=") })
            .flatMap { PackageUpdateCondition(rawValue: String($0.dropFirst("--update-notes=".count))) } ?? .ifNewer
        let updateNotetypes = args.first(where: { $0.hasPrefix("--update-notetypes=") })
            .flatMap { PackageUpdateCondition(rawValue: String($0.dropFirst("--update-notetypes=".count))) } ?? .ifNewer
        let message = try await ApkgImporter(store: store).importPackage(
            at: URL(fileURLWithPath: path),
            withScheduling: flags.contains("--scheduling"),
            withDeckConfigs: flags.contains("--presets"),
            mergeNotetypes: flags.contains("--merge-notetypes"),
            updateNotes: updateNotes,
            updateNotetypes: updateNotetypes
        )
        return [
            "message": message,
            "decks": store.decks.count,
            "notes": try store.db.scalarInt("SELECT COUNT(*) FROM notes"),
            "cards": try store.db.scalarInt("SELECT COUNT(*) FROM cards"),
            "media": (try? FileManager.default.contentsOfDirectory(atPath: store.mediaRoot.path).count) ?? 0,
        ]
    }

    static func exportPackage(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard let path = args.first, !path.isEmpty else {
            throw SQLiteError.exec("export <package.apkg>")
        }
        let options = ApkgExportOptions(configuration: [
            "apkgIncludeScheduling": args.contains("--scheduling"),
            "apkgIncludeDeckPresets": args.contains("--presets"),
            "apkgIncludeMedia": !args.contains("--no-media"),
        ])
        let destination = URL(fileURLWithPath: path)
        try ApkgExporter(store: store).export(deckID: nil, to: destination, options: options)
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        return ["path": path, "bytes": size]
    }

    static func backup(_ store: CollectionStore) throws -> [String: Any] {
        guard let url = try store.createAutomaticBackupIfNeeded(force: true) else {
            throw SQLiteError.exec("Automatic backup was not created")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return [
            "path": url.path,
            "name": url.lastPathComponent,
            "bytes": size,
            "count": try store.collectionBackupPackages().count
        ]
    }

    static func csvImport(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard let path = args.first, !path.isEmpty else {
            throw SQLiteError.exec("csv-import <file.csv>")
        }
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let policy = args.first(where: { $0.hasPrefix("--policy=") })
            .flatMap { CSVImporter.ExistingNotePolicy(rawValue: String($0.dropFirst("--policy=".count))) }
        let result = try CSVImporter(store: store).importText(
            text,
            allowHTML: args.contains("--no-html") ? false : nil,
            existingNotePolicy: policy,
            matchWithinDeck: args.contains("--match-within-deck") ? true : nil
        )
        return [
            "added": result.added,
            "updated": result.updated,
            "ignored": result.ignored,
            "notes": try store.db.scalarInt("SELECT COUNT(*) FROM notes"),
            "cards": try store.db.scalarInt("SELECT COUNT(*) FROM cards")
        ]
    }

    static func csvExport(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard let path = args.first, !path.isEmpty else {
            throw SQLiteError.exec("csv-export <file.tsv>")
        }
        let destination = URL(fileURLWithPath: path)
        try CSVExporter(store: store).exportNotes(to: destination)
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        return ["path": path, "bytes": size]
    }

    static func filteredRebuild(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard args.count >= 3, let limit = Int(args[1]) else {
            throw SQLiteError.exec("filtered-rebuild <search> <limit> <order> [--no-reschedule]")
        }
        let deck = try store.createFilteredDeck()
        let secondSearch = args.first(where: { $0.hasPrefix("--second-search=") })
            .map { String($0.dropFirst("--second-search=".count)) }
        let secondLimit = args.first(where: { $0.hasPrefix("--second-limit=") })
            .flatMap { Int($0.dropFirst("--second-limit=".count)) } ?? 20
        let secondOrder = args.first(where: { $0.hasPrefix("--second-order=") })
            .map { String($0.dropFirst("--second-order=".count)) } ?? "due"
        let savedDeck = try store.saveFilteredDeck(
            deck,
            search: args[0],
            limit: limit,
            order: args[2],
            reschedule: !args.contains("--no-reschedule"),
            again: 60,
            hard: 600,
            good: 0,
            allowEmpty: args.contains("--allow-empty"),
            search2: secondSearch,
            limit2: secondLimit,
            order2: secondOrder
        )
        if args.contains("--repeat-rebuild"), let saved = store.deck(id: savedDeck.id) {
            try FilteredDeckSupport.empty(saved, store: store)
            try store.db.run("UPDATE cards SET mod = 43")
            try FilteredDeckSupport.rebuild(saved, store: store)
        }
        var filled: [[String: Any]] = []
        var selectedIDs: [Int64] = []
        try store.db.query("""
            SELECT id, type, queue, due, ivl, odue, did, ord, usn
            FROM cards WHERE odid != 0 ORDER BY due, id
            """) { stmt in
            let cardID = sqlite3_column_int64(stmt, 0)
            selectedIDs.append(cardID)
            filled.append([
                "id": cardID,
                "type": Int(sqlite3_column_int(stmt, 1)),
                "queue": Int(sqlite3_column_int(stmt, 2)),
                "due": Int(sqlite3_column_int(stmt, 3)),
                "ivl": Int(sqlite3_column_int(stmt, 4)),
                "odue": Int(sqlite3_column_int(stmt, 5)),
                "deck": "filtered",
                "ord": Int(sqlite3_column_int(stmt, 7)),
                "usn": Int(sqlite3_column_int(stmt, 8))
            ])
        }
        for index in filled.indices {
            filled[index]["templateDeck"] = try store.search(query: "cid:\(selectedIDs[index])", limit: 1).first?.templateDeckName ?? ""
        }
        try FilteredDeckSupport.empty(store.deck(id: savedDeck.id) ?? savedDeck, store: store)
        var emptied: [[String: Any]] = []
        for cardID in selectedIDs {
            guard let card = try store.fetchCard(id: cardID) else { continue }
            let templateDeckName = try store.search(query: "cid:\(cardID)", limit: 1).first?.templateDeckName ?? ""
            emptied.append([
                "id": card.id,
                "type": card.type,
                "queue": card.queue,
                "due": card.due,
                "ivl": card.ivl,
                "odue": card.odue,
                "deck": store.deck(id: card.did)?.name ?? "",
                "templateDeck": templateDeckName,
                "ord": card.ord,
                "usn": card.usn
            ])
        }
        return ["filled": filled, "emptied": emptied]
    }

    static func queueActions(_ store: CollectionStore, args: [String]) throws -> [[String: Any]] {
        guard let action = args.first else { throw SQLiteError.exec("queue-actions <suspend|bury|unbury|unsuspend>") }
        var ids: [Int64] = []
        for queue in [0, -1, -2, -3] {
            try store.db.query("SELECT id FROM cards WHERE queue = ? ORDER BY id LIMIT 1", bind: { stmt in
                SQLiteDatabase.bindInt(stmt, 1, queue)
            }) { stmt in
                ids.append(sqlite3_column_int64(stmt, 0))
            }
        }
        guard ids.count == 4 else { throw SQLiteError.exec("Fixture must contain cards in each queue") }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try store.db.run("UPDATE cards SET usn = 42 WHERE id IN (\(placeholders))") { stmt in
            for (index, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
        }
        switch action {
        case "suspend": try store.setCardsQueue(ids, queue: -1)
        case "bury": try store.buryCards(ids)
        case "unbury": try store.unburyCards(ids)
        case "unsuspend": try store.unsuspendCards(ids)
        default: throw SQLiteError.exec("Unsupported queue action")
        }
        var result: [[String: Any]] = []
        try store.db.query("SELECT id, queue, usn FROM cards WHERE id IN (\(placeholders)) ORDER BY id", bind: { stmt in
            for (index, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
        }) { stmt in
            result.append([
                "id": sqlite3_column_int64(stmt, 0),
                "queue": Int(sqlite3_column_int(stmt, 1)),
                "usn": Int(sqlite3_column_int(stmt, 2))
            ])
        }
        return result
    }

    static func deleteActions(_ store: CollectionStore) throws -> [String: Any] {
        let noteID = try store.db.scalarInt64("""
            SELECT n.id FROM notes n
            JOIN cards c ON c.nid = n.id
            JOIN revlog r ON r.cid = c.id
            ORDER BY n.id LIMIT 1
            """)
        var originalCardIDs: [Int64] = []
        try store.db.query("SELECT id FROM cards WHERE nid = ? ORDER BY id", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) { stmt in
            originalCardIDs.append(sqlite3_column_int64(stmt, 0))
        }
        func snapshot() throws -> [String: Any] {
            var noteRows: [[String: Any]] = []
            try store.db.query("SELECT id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data FROM notes WHERE id = ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, noteID)
            }) { stmt in
                noteRows.append([
                    "id": sqlite3_column_int64(stmt, 0),
                    "guid": String(cString: sqlite3_column_text(stmt, 1)),
                    "mid": sqlite3_column_int64(stmt, 2),
                    "mod": sqlite3_column_int64(stmt, 3),
                    "usn": Int(sqlite3_column_int(stmt, 4)),
                    "tags": String(cString: sqlite3_column_text(stmt, 5)),
                    "flds": String(cString: sqlite3_column_text(stmt, 6)),
                    "sfld": String(cString: sqlite3_column_text(stmt, 7)),
                    "csum": sqlite3_column_int64(stmt, 8),
                    "flags": Int(sqlite3_column_int(stmt, 9)),
                    "data": String(cString: sqlite3_column_text(stmt, 10))
                ])
            }
            var cards: [[String: Any]] = []
            try store.db.query("SELECT id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data FROM cards WHERE nid = ? ORDER BY id", bind: {
                SQLiteDatabase.bindInt64($0, 1, noteID)
            }) { stmt in
                let cardID = sqlite3_column_int64(stmt, 0)
                cards.append([
                    "id": cardID,
                    "nid": sqlite3_column_int64(stmt, 1),
                    "did": sqlite3_column_int64(stmt, 2),
                    "ord": Int(sqlite3_column_int(stmt, 3)),
                    "mod": sqlite3_column_int64(stmt, 4),
                    "usn": Int(sqlite3_column_int(stmt, 5)),
                    "type": Int(sqlite3_column_int(stmt, 6)),
                    "queue": Int(sqlite3_column_int(stmt, 7)),
                    "due": Int(sqlite3_column_int(stmt, 8)),
                    "ivl": Int(sqlite3_column_int(stmt, 9)),
                    "factor": Int(sqlite3_column_int(stmt, 10)),
                    "reps": Int(sqlite3_column_int(stmt, 11)),
                    "lapses": Int(sqlite3_column_int(stmt, 12)),
                    "left": Int(sqlite3_column_int(stmt, 13)),
                    "odue": Int(sqlite3_column_int(stmt, 14)),
                    "odid": sqlite3_column_int64(stmt, 15),
                    "flags": Int(sqlite3_column_int(stmt, 16)),
                    "data": String(cString: sqlite3_column_text(stmt, 17))
                ])
            }
            var graves: [[String: Int64]] = []
            var revlog: [[String: Int64]] = []
            if !originalCardIDs.isEmpty {
                let placeholders = originalCardIDs.map { _ in "?" }.joined(separator: ",")
                try store.db.query("SELECT usn, oid, type FROM graves WHERE (type = 0 AND oid IN (\(placeholders))) OR (type = 1 AND oid = ?) ORDER BY type, oid, usn", bind: { stmt in
                    for (index, id) in originalCardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                    SQLiteDatabase.bindInt64(stmt, Int32(originalCardIDs.count + 1), noteID)
                }) { stmt in
                    graves.append(["usn": Int64(sqlite3_column_int(stmt, 0)), "oid": sqlite3_column_int64(stmt, 1), "type": Int64(sqlite3_column_int(stmt, 2))])
                }
                try store.db.query("SELECT id, cid, usn, ease, ivl, lastIvl, factor, time, type FROM revlog WHERE cid IN (\(placeholders)) ORDER BY id", bind: { stmt in
                    for (index, id) in originalCardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                }) { stmt in
                    revlog.append([
                        "id": sqlite3_column_int64(stmt, 0),
                        "cid": sqlite3_column_int64(stmt, 1),
                        "usn": Int64(sqlite3_column_int(stmt, 2)),
                        "ease": Int64(sqlite3_column_int(stmt, 3)),
                        "ivl": Int64(sqlite3_column_int(stmt, 4)),
                        "lastIvl": Int64(sqlite3_column_int(stmt, 5)),
                        "factor": Int64(sqlite3_column_int(stmt, 6)),
                        "time": Int64(sqlite3_column_int(stmt, 7)),
                        "type": Int64(sqlite3_column_int(stmt, 8))
                    ])
                }
            }
            return ["notes": noteRows, "cards": cards, "graves": graves, "revlog": revlog]
        }

        let before = try snapshot()
        try store.deleteNotesUndoably(ids: [noteID])
        let deleted = try snapshot()
        try store.undoMostRecentCollectionAction()
        let undone = try snapshot()
        try store.redoMostRecentCollectionAction()
        let redone = try snapshot()
        return ["deleted": deleted, "undone": undone, "redone": redone, "before": before]
    }

    static func deckActions(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard let action = args.first else { throw SQLiteError.exec("deck-actions <rename|delete|insertion-order>") }
        if action == "insertion-order" {
            guard let deck = store.decks.first(where: { $0.name == "Lang::ES" }),
                  let reversed = store.notetypes.first(where: { $0.name == "Basic (and reversed card)" }),
                  var config = store.deckConfigs.first(where: { $0.id == deck.conf }) else {
                throw SQLiteError.exec("Insertion-order fixture is incomplete")
            }
            try store.addNote(mid: reversed.id, did: deck.id, fields: ["Insertion order front", "Insertion order back"], tags: "", guid: "parity-insertion-order")
            try store.db.run("UPDATE cards SET usn = 42 WHERE (did = ? OR (odid != 0 AND odid = ?)) AND type = 0") { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, deck.id)
                SQLiteDatabase.bindInt64(stmt, 2, deck.id)
            }
            config.new.order = 0
            var configs = store.deckConfigs
            if let index = configs.firstIndex(where: { $0.id == config.id }) { configs[index] = config }
            try store.saveDeckConfigs(configs)
            config.new.order = 1
            configs = store.deckConfigs
            if let index = configs.firstIndex(where: { $0.id == config.id }) { configs[index] = config }
            try store.saveDeckConfigs(configs)
            var cards: [[String: Any]] = []
            try store.db.query("SELECT n.guid, c.ord, c.did, c.odid, c.queue, c.due, c.odue, c.usn FROM cards c JOIN notes n ON n.id = c.nid WHERE (c.did = ? OR (c.odid != 0 AND c.odid = ?)) AND c.type = 0 ORDER BY n.guid, c.ord", bind: { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, deck.id)
                SQLiteDatabase.bindInt64(stmt, 2, deck.id)
            }) { stmt in
                cards.append([
                    "guid": String(cString: sqlite3_column_text(stmt, 0)),
                    "ord": Int64(sqlite3_column_int(stmt, 1)),
                    "did": sqlite3_column_int64(stmt, 2),
                    "odid": sqlite3_column_int64(stmt, 3),
                    "queue": Int64(sqlite3_column_int(stmt, 4)),
                    "due": sqlite3_column_int64(stmt, 5),
                    "odue": sqlite3_column_int64(stmt, 6),
                    "usn": Int64(sqlite3_column_int(stmt, 7))
                ])
            }
            return ["cards": cards]
        }
        if action == "filtered-delete" {
            return try filteredDeckDeleteActions(store)
        }
        if action.hasPrefix("create") {
            let name: String
            let parent: AnkiDeck?
            switch action {
            case "create": name = "New::Leaf"; parent = nil
            case "create-normalized": name = "lANG::New::::Leaf"; parent = nil
            case "create-existing": name = "lang::jp"; parent = nil
            case "create-parented":
                name = "New::Leaf"
                parent = store.decks.first(where: { $0.name == "Lang" })
            default: throw SQLiteError.exec("Unknown deck creation case")
            }
            let baseline = store.decks.sorted { $0.id < $1.id }.enumerated().map { index, deck in
                var copy = deck
                copy.mod = Int64(700 + index)
                return copy
            }
            try store.saveDecks(baseline)
            let originalIDs = Set(store.decks.map(\.id))
            func snapshot(_ decks: [AnkiDeck]) -> [[String: Any]] {
                decks.sorted { $0.id < $1.id }.map { deck in
                    let id: Any = originalIDs.contains(deck.id) ? deck.id as Any : "new:\(deck.name)"
                    let mod: Any = deck.mod > 1_000_000_000 ? "updated" : deck.mod
                    return ["id": id, "name": deck.name, "mod": mod, "usn": deck.usn]
                }
            }
            let before = snapshot(store.decks)
            try store.createDeck(name: name, parent: parent)
            let after = snapshot(store.decks)
            try store.undoMostRecentCollectionAction()
            let undone = snapshot(store.decks)
            try store.redoMostRecentCollectionAction()
            let redone = snapshot(store.decks)
            return ["before": before, "after": after, "undone": undone, "redone": redone]
        }
        if action.hasPrefix("reparent") {
            let fixtureIDs = Set(store.decks.map(\.id))
            if action == "reparent-collision" {
                try store.createDeck(name: "JP", parent: store.decks.first(where: { $0.name == "Lang::ES" }))
            }
            let sourceName = action == "reparent-descendant" ? "Lang" : "Lang::JP"
            guard let source = store.decks.first(where: { $0.name == sourceName }) else {
                throw SQLiteError.exec("\(sourceName) deck was not found")
            }
            let targetName = action == "reparent-root" ? nil : "Lang::ES"
            let target = targetName.flatMap { name in store.decks.first(where: { $0.name == name }) }
            let baseline = store.decks.sorted { $0.id < $1.id }.enumerated().map { index, deck in
                var copy = deck
                copy.mod = Int64(700 + index)
                return copy
            }
            try store.saveDecks(baseline)
            let originalIDs = fixtureIDs
            func snapshot(_ decks: [AnkiDeck]) -> [[String: Any]] {
                decks.sorted { $0.id < $1.id }.map { deck in
                    let id: Any = originalIDs.contains(deck.id) ? deck.id as Any : "new:\(deck.name)"
                    let mod: Any = deck.mod > 1_000_000_000 ? "updated" : deck.mod
                    return ["id": id, "name": deck.name, "mod": mod, "usn": deck.usn]
                }
            }
            let before = snapshot(store.decks)
            try store.reparentDeck(source, to: target)
            let after = snapshot(store.decks)
            try store.undoMostRecentCollectionAction()
            let undone = snapshot(store.decks)
            try store.redoMostRecentCollectionAction()
            let redone = snapshot(store.decks)
            return ["before": before, "after": after, "undone": undone, "redone": redone]
        }
        if action.hasPrefix("rename") {
            let targetName = action == "rename-root" ? "Lang" : "Lang::JP"
            let newName: String
            switch action {
            case "rename": newName = "Lang::Japanese"
            case "rename-conflict": newName = "Lang::ES"
            case "rename-normalized": newName = "lANG::New::::Leaf"
            case "rename-nested": newName = "Lang::JP::Kana::Leaf"
            case "rename-root": newName = "Lang::Archive"
            case "rename-case": newName = "lang::jP"
            default: throw SQLiteError.exec("Unknown deck rename case")
            }
            guard let target = store.decks.first(where: { $0.name == targetName }) else {
                throw SQLiteError.exec("\(targetName) deck was not found")
            }
            let baseline = store.decks.sorted { $0.id < $1.id }.enumerated().map { index, deck in
                var copy = deck
                copy.mod = Int64(700 + index)
                return copy
            }
            try store.saveDecks(baseline)
            let originalIDs = Set(store.decks.map(\.id))
            func snapshot(_ decks: [AnkiDeck]) -> [[String: Any]] {
                decks.sorted { $0.id < $1.id }.map { deck in
                    let id: Any = originalIDs.contains(deck.id) ? deck.id as Any : "new:\(deck.name)"
                    let mod: Any = deck.mod > 1_000_000_000 ? "updated" : deck.mod
                    return [
                        "id": id,
                        "name": deck.name,
                        "mod": mod,
                        "usn": deck.usn
                    ]
                }
            }
            let before = snapshot(store.decks)
            try store.renameDeck(target, to: newName)
            let after = snapshot(store.decks)
            try store.undoMostRecentCollectionAction()
            let undone = snapshot(store.decks)
            try store.redoMostRecentCollectionAction()
            let redone = snapshot(store.decks)
            return ["before": before, "after": after, "undone": undone, "redone": redone]
        }
        guard action == "delete",
              let parent = store.decks.first(where: { $0.name == "Lang::JP" }),
              let child = store.decks.first(where: { $0.name == "Lang::JP::Kana" }),
              let outside = store.decks.first(where: { $0.name == "Math" }),
              let basic = store.notetypes.first(where: { $0.name == "Basic" }),
              let reversed = store.notetypes.first(where: { $0.name == "Basic (and reversed card)" }) else {
            throw SQLiteError.exec("Deck deletion fixture is incomplete")
        }
        try store.addNote(mid: basic.id, did: parent.id, fields: ["Deck delete parent", "parent"], tags: "", guid: "parity-deck-parent")
        try store.addNote(mid: reversed.id, did: child.id, fields: ["Deck delete shared", "shared"], tags: "", guid: "parity-deck-shared")
        try store.db.run("UPDATE notes SET mod = 401, usn = 40 WHERE guid LIKE 'parity-deck-%'")
        try store.db.run("UPDATE cards SET mod = 402, usn = 41 WHERE nid IN (SELECT id FROM notes WHERE guid LIKE 'parity-deck-%')")
        let sharedNoteID = try store.db.scalarInt64("SELECT id FROM notes WHERE guid = ?") {
            try SQLiteDatabase.bindText($0, 1, "parity-deck-shared")
        }
        try store.db.run("UPDATE cards SET did = ?, mod = 987, usn = 42 WHERE nid = ? AND ord = 1") {
            SQLiteDatabase.bindInt64($0, 1, outside.id)
            SQLiteDatabase.bindInt64($0, 2, sharedNoteID)
        }
        let deckNames = Dictionary(uniqueKeysWithValues: store.decks.map { ($0.id, $0.name) })
        var noteNames: [Int64: String] = [:]
        var cardNames: [Int64: String] = [:]
        try store.db.query("SELECT id, guid FROM notes") { stmt in
            noteNames[sqlite3_column_int64(stmt, 0)] = String(cString: sqlite3_column_text(stmt, 1))
        }
        try store.db.query("SELECT c.id, n.guid, c.ord FROM cards c JOIN notes n ON n.id = c.nid") { stmt in
            cardNames[sqlite3_column_int64(stmt, 0)] = "\(String(cString: sqlite3_column_text(stmt, 1)))#\(sqlite3_column_int(stmt, 2))"
        }
        var priorGraves = Set<String>()
        try store.db.query("SELECT usn, oid, type FROM graves") { stmt in
            priorGraves.insert("\(sqlite3_column_int(stmt, 0))|\(sqlite3_column_int64(stmt, 1))|\(sqlite3_column_int(stmt, 2))")
        }
        func snapshot() throws -> [String: Any] {
            var notes: [[String: Any]] = []
            try store.db.query("SELECT guid, mid, mod, usn, tags, flds, sfld, csum FROM notes WHERE guid LIKE 'parity-deck-%' ORDER BY guid") { stmt in
                notes.append([
                    "guid": String(cString: sqlite3_column_text(stmt, 0)),
                    "mid": sqlite3_column_int64(stmt, 1),
                    "mod": sqlite3_column_int64(stmt, 2),
                    "usn": Int(sqlite3_column_int(stmt, 3)),
                    "tags": String(cString: sqlite3_column_text(stmt, 4)),
                    "flds": String(cString: sqlite3_column_text(stmt, 5)),
                    "sfld": String(cString: sqlite3_column_text(stmt, 6)),
                    "csum": sqlite3_column_int64(stmt, 7)
                ])
            }
            var cards: [[String: Any]] = []
            try store.db.query("""
                SELECT n.guid, c.ord, c.did, c.type, c.queue, c.due, c.ivl, c.mod, c.usn
                FROM cards c JOIN notes n ON n.id = c.nid
                WHERE n.guid LIKE 'parity-deck-%'
                ORDER BY n.guid, c.ord
                """) { stmt in
                let did = sqlite3_column_int64(stmt, 2)
                cards.append([
                    "guid": String(cString: sqlite3_column_text(stmt, 0)),
                    "ord": Int(sqlite3_column_int(stmt, 1)),
                    "deck": deckNames[did] ?? "",
                    "type": Int(sqlite3_column_int(stmt, 3)),
                    "queue": Int(sqlite3_column_int(stmt, 4)),
                    "due": sqlite3_column_int64(stmt, 5),
                    "ivl": sqlite3_column_int(stmt, 6),
                    "mod": sqlite3_column_int64(stmt, 7),
                    "usn": Int(sqlite3_column_int(stmt, 8))
                ])
            }
            let decks = store.decks.sorted { $0.id < $1.id }.map { [
                "id": $0.id,
                "name": $0.name,
                "mod": $0.mod,
                "usn": $0.usn
            ] }
            var newGraves: [[String: Any]] = []
            try store.db.query("SELECT usn, oid, type FROM graves ORDER BY type, oid, usn") { stmt in
                let usn = sqlite3_column_int(stmt, 0)
                let oid = sqlite3_column_int64(stmt, 1)
                let type = sqlite3_column_int(stmt, 2)
                let key = "\(usn)|\(oid)|\(type)"
                guard !priorGraves.contains(key) else { return }
                let subject: String
                switch type {
                case 0: subject = cardNames[oid] ?? ""
                case 1: subject = noteNames[oid] ?? ""
                case 2: subject = deckNames[oid] ?? ""
                default: subject = ""
                }
                newGraves.append(["usn": Int64(usn), "type": Int64(type), "subject": subject])
            }
            return ["decks": decks, "notes": notes, "cards": cards, "newGraves": newGraves]
        }
        let before = try snapshot()
        try store.deleteDeck(parent, cardsToo: true)
        let deleted = try snapshot()
        try store.undoMostRecentCollectionAction()
        let undone = try snapshot()
        try store.redoMostRecentCollectionAction()
        let redone = try snapshot()
        return ["before": before, "after": deleted, "undone": undone, "redone": redone]
    }

    static func filteredDeckDeleteActions(_ store: CollectionStore) throws -> [String: Any] {
        guard let parent = store.decks.first(where: { $0.name == "Lang::JP" }),
              let basic = store.notetypes.first(where: { $0.name == "Basic" }) else {
            throw SQLiteError.exec("Filtered deck deletion fixture is incomplete")
        }
        let filteredID: Int64 = 9_000_000_000_000_000
        let filtered = AnkiDeck(
            id: filteredID,
            name: "ParityFiltered",
            mod: 401,
            usn: -1,
            collapsed: false,
            browserCollapsed: false,
            desc: "",
            dyn: 1,
            conf: 1,
            extendNew: 0,
            extendRev: 0,
            newToday: [0, 0],
            revToday: [0, 0],
            lrnToday: [0, 0],
            timeToday: [0, 0],
            searchTerms: "",
            termLimit: 100,
            resched: true,
            previewDelay: 10,
            searchOrder: "random",
            previewAgain: 60,
            previewHard: 600,
            previewGood: 0
        )
        try store.saveDecks(store.decks + [filtered])
        try store.addNote(mid: basic.id, did: parent.id, fields: ["Filtered deck card", "back"], tags: "", guid: "parity-deck-filtered")
        let noteID = try store.db.scalarInt64("SELECT id FROM notes WHERE guid = ?") {
            try SQLiteDatabase.bindText($0, 1, "parity-deck-filtered")
        }
        let cardID = try store.db.scalarInt64("SELECT id FROM cards WHERE nid = ?") {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }
        try store.db.run("""
            UPDATE cards SET did = ?, odid = ?, odue = due, due = -100000, mod = 402, usn = 41
            WHERE id = ?
            """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, filteredID)
            SQLiteDatabase.bindInt64(stmt, 2, parent.id)
            SQLiteDatabase.bindInt64(stmt, 3, cardID)
        }
        let deckNames = Dictionary(uniqueKeysWithValues: store.decks.map { ($0.id, $0.name) })
        func snapshot() throws -> [String: Any] {
            let decks = store.decks.sorted { $0.id < $1.id }.map { [
                "id": $0.id,
                "name": $0.name,
                "mod": $0.mod,
                "usn": $0.usn
            ] }
            let noteExists = try store.db.scalarInt("SELECT COUNT(*) FROM notes WHERE id = ?") {
                SQLiteDatabase.bindInt64($0, 1, noteID)
            } != 0
            var card: [String: Any] = [:]
            try store.db.query("SELECT did, odid, odue, due, type, queue, mod, usn FROM cards WHERE id = ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, cardID)
            }) { stmt in
                let did = sqlite3_column_int64(stmt, 0)
                card = [
                    "deck": deckNames[did] ?? "",
                    "odid": sqlite3_column_int64(stmt, 1),
                    "odue": sqlite3_column_int(stmt, 2),
                    "due": sqlite3_column_int(stmt, 3),
                    "type": Int(sqlite3_column_int(stmt, 4)),
                    "queue": Int(sqlite3_column_int(stmt, 5)),
                    "mod": sqlite3_column_int64(stmt, 6),
                    "usn": Int(sqlite3_column_int(stmt, 7))
                ]
            }
            var graves: [[String: Any]] = []
            try store.db.query("""
                SELECT usn, oid, type FROM graves
                WHERE (type = 0 AND oid = ?) OR (type = 2 AND oid = ?)
                ORDER BY type, oid, usn
                """, bind: { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, cardID)
                SQLiteDatabase.bindInt64(stmt, 2, filteredID)
            }) { stmt in
                let type = sqlite3_column_int(stmt, 2)
                graves.append([
                    "usn": Int64(sqlite3_column_int(stmt, 0)),
                    "type": Int64(type),
                    "subject": type == 0 ? "parity-deck-filtered#0" : "ParityFiltered"
                ])
            }
            return ["decks": decks, "noteExists": noteExists, "card": card, "graves": graves]
        }
        let before = try snapshot()
        try store.deleteDeck(filtered, cardsToo: true)
        let deleted = try snapshot()
        try store.undoMostRecentCollectionAction()
        let undone = try snapshot()
        try store.redoMostRecentCollectionAction()
        let redone = try snapshot()
        return ["before": before, "after": deleted, "undone": undone, "redone": redone]
    }

    static func cardgenActions(_ store: CollectionStore) throws -> [[String: Any]] {
        guard let modelIndex = store.notetypes.firstIndex(where: { $0.name == "Basic" }) else {
            throw SQLiteError.exec("Basic note type was not found")
        }
        var updatedModel = store.notetypes[modelIndex]
        let firstSpecialOrd = updatedModel.tmpls.count
        updatedModel.tmpls.append(AnkiTemplate(
            name: "Deck special",
            ord: firstSpecialOrd,
            qfmt: "{{Deck}}",
            afmt: "{{FrontSide}}"
        ))
        updatedModel.tmpls.append(AnkiTemplate(
            name: "Tags special",
            ord: firstSpecialOrd + 1,
            qfmt: "{{Tags}}",
            afmt: "{{FrontSide}}"
        ))
        updatedModel.tmpls.append(AnkiTemplate(
            name: "Conditional",
            ord: firstSpecialOrd + 2,
            qfmt: "{{#Front}}{{Front}}{{/Front}}",
            afmt: "{{FrontSide}}"
        ))
        updatedModel.tmpls.append(AnkiTemplate(
            name: "Negated",
            ord: firstSpecialOrd + 3,
            qfmt: "{{^Back}}{{Front}}{{/Back}}",
            afmt: "{{FrontSide}}"
        ))
        var updatedModels = store.notetypes
        updatedModels[modelIndex] = updatedModel
        try store.saveNotetypes(updatedModels)

        let cases: [(guid: String, fields: [String], tags: String)] = [
            ("parity-special-no-tags", ["", ""], ""),
            ("parity-special-with-tags", ["", ""], "parity"),
            ("parity-conditional-front", ["front", ""], ""),
            ("parity-conditional-both", ["front", "back"], "")
        ]
        var result: [[String: Any]] = []
        for item in cases {
            try store.addNote(
                mid: updatedModel.id,
                did: 1,
                fields: item.fields,
                tags: item.tags,
                guid: item.guid
            )
            var ords: [Int] = []
            try store.db.query("SELECT ord FROM cards WHERE nid = (SELECT id FROM notes WHERE guid = ?) ORDER BY ord", bind: {
                try SQLiteDatabase.bindText($0, 1, item.guid)
            }) { stmt in
                ords.append(Int(sqlite3_column_int(stmt, 0)))
            }
            result.append(["tags": item.tags, "ords": ords])
        }
        return result
    }

    static func notetypeSchemaActions(_ store: CollectionStore) throws -> [[String: Int64]] {
        guard let modelIndex = store.notetypes.firstIndex(where: { $0.name == "Basic" }) else {
            throw SQLiteError.exec("Basic note type was not found")
        }
        let original = store.notetypes[modelIndex]
        var updated = original
        updated.tmpls.append(AnkiTemplate(
            name: "Parity added card",
            ord: updated.tmpls.count,
            qfmt: "{{Back}}",
            afmt: "{{FrontSide}}"
        ))
        let noteID = try store.db.scalarInt64("""
            SELECT n.id FROM notes n
            JOIN cards c ON c.nid = n.id
            WHERE n.mid = ? AND c.queue = 0
            ORDER BY n.id LIMIT 1
            """) { SQLiteDatabase.bindInt64($0, 1, original.id) }
        try store.saveEditedNotetype(updated, replacing: original)
        var cards: [[String: Int64]] = []
        try store.db.query("SELECT ord, did, type, queue, due, usn FROM cards WHERE nid = ? ORDER BY ord", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) { stmt in
            cards.append([
                "ord": Int64(sqlite3_column_int(stmt, 0)),
                "did": sqlite3_column_int64(stmt, 1),
                "type": Int64(sqlite3_column_int(stmt, 2)),
                "queue": Int64(sqlite3_column_int(stmt, 3)),
                "due": Int64(sqlite3_column_int(stmt, 4)),
                "usn": Int64(sqlite3_column_int(stmt, 5))
            ])
        }
        return cards
    }

    static func emptyActions(_ store: CollectionStore) throws -> [String: Any] {
        guard let model = store.notetypes.first(where: { $0.name == "Basic" }) else {
            throw SQLiteError.exec("Basic note type was not found")
        }
        let noteID = try store.db.scalarInt64("""
            SELECT n.id FROM notes n
            JOIN cards c ON c.nid = n.id
            WHERE n.mid = ? AND c.queue = 0
            ORDER BY n.id LIMIT 1
            """) { SQLiteDatabase.bindInt64($0, 1, model.id) }
        guard let note = try store.fetchNote(id: noteID), !note.fields.isEmpty else {
            throw SQLiteError.exec("Fixture note was not found")
        }
        var cardIDs: [Int64] = []
        try store.db.query("SELECT id FROM cards WHERE nid = ? ORDER BY id", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) { stmt in
            cardIDs.append(sqlite3_column_int64(stmt, 0))
        }
        var fields = note.fields
        fields[0] = ""
        try store.updateNote(note, fields: fields, tags: note.tags)
        let removed = try store.emptyCards()
        let placeholders = cardIDs.map { _ in "?" }.joined(separator: ",")
        var remainingCards: [Int64] = []
        try store.db.query("SELECT id FROM cards WHERE nid = ? ORDER BY id", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) { stmt in
            remainingCards.append(sqlite3_column_int64(stmt, 0))
        }
        var graves: [[String: Int64]] = []
        var revlogIDs: [Int64] = []
        if !cardIDs.isEmpty {
            try store.db.query("SELECT usn, oid, type FROM graves WHERE (type = 0 AND oid IN (\(placeholders))) OR (type = 1 AND oid = ?) ORDER BY type, oid, usn", bind: { stmt in
                for (index, id) in cardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                SQLiteDatabase.bindInt64(stmt, Int32(cardIDs.count + 1), noteID)
            }) { stmt in
                graves.append(["usn": Int64(sqlite3_column_int(stmt, 0)), "oid": sqlite3_column_int64(stmt, 1), "type": Int64(sqlite3_column_int(stmt, 2))])
            }
            try store.db.query("SELECT id FROM revlog WHERE cid IN (\(placeholders)) ORDER BY id", bind: { stmt in
                for (index, id) in cardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }) { stmt in
                revlogIDs.append(sqlite3_column_int64(stmt, 0))
            }
        }
        let noteExists = try store.db.scalarInt("SELECT COUNT(*) FROM notes WHERE id = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) != 0
        return [
            "removed": removed,
            "noteExists": noteExists,
            "cards": remainingCards,
            "graves": graves,
            "revlogIDs": revlogIDs
        ]
    }

    static func syncActions(_ store: CollectionStore, args: [String]) throws -> [[String: Any]] {
        guard let action = args.first else { throw SQLiteError.exec("sync-actions <set-due|reset|reposition|reposition-siblings|reposition-mixed|reposition-suspended|move>") }
        try store.db.exec("UPDATE cards SET usn = 43")
        var cardIDs: [Int64] = []
        switch action {
        case "set-due":
            let cardID = try store.db.scalarInt64("SELECT id FROM cards WHERE queue = 0 ORDER BY id LIMIT 1")
            try store.setDueDate(cardIDs: [cardID], daysFromToday: 4)
        case "reset":
            let cardID = try store.db.scalarInt64("SELECT id FROM cards WHERE queue = 2 ORDER BY id LIMIT 1")
            try store.resetCards([cardID], restoreOriginalPosition: true)
        case "reposition":
            cardIDs = [try store.db.scalarInt64("SELECT id FROM cards WHERE queue = 0 ORDER BY due DESC, id LIMIT 1")]
        case "reposition-siblings":
            try store.db.query("""
                SELECT id FROM cards
                WHERE nid = (
                    SELECT nid FROM cards GROUP BY nid HAVING COUNT(*) >= 2 ORDER BY nid LIMIT 1
                )
                ORDER BY id LIMIT 2
                """) { stmt in cardIDs.append(sqlite3_column_int64(stmt, 0)) }
            guard cardIDs.count == 2 else { throw SQLiteError.exec("Fixture must contain a sibling pair") }
            for cardID in cardIDs {
                try store.db.run("UPDATE cards SET type = 0, queue = 0 WHERE id = ?") {
                    SQLiteDatabase.bindInt64($0, 1, cardID)
                }
            }
        case "reposition-mixed":
            cardIDs = [
                try store.db.scalarInt64("SELECT id FROM cards WHERE queue = 0 ORDER BY id LIMIT 1"),
                try store.db.scalarInt64("SELECT id FROM cards WHERE queue = 2 ORDER BY id LIMIT 1")
            ]
        case "reposition-suspended":
            let cardID = try store.db.scalarInt64("SELECT id FROM cards WHERE queue = 0 ORDER BY id LIMIT 1")
            try store.db.run("UPDATE cards SET queue = -1 WHERE id = ?") { SQLiteDatabase.bindInt64($0, 1, cardID) }
            cardIDs = [cardID]
        case "move":
            let cardID = try store.db.scalarInt64("SELECT id FROM cards ORDER BY id LIMIT 1")
            guard let target = store.decks.first(where: { $0.name == "Lang::ES" }) else {
                throw SQLiteError.exec("Fixture target deck was not found")
            }
            try store.moveCards([cardID], toDeck: target.id)
        default:
            throw SQLiteError.exec("Unsupported sync action")
        }
        if action.hasPrefix("reposition") {
            try store.repositionNewCards(
                cardIDs,
                startingFrom: 5,
                step: 2,
                random: false,
                shift: action == "reposition" || action == "reposition-mixed"
            )
        }
        var result: [[String: Any]] = []
        try store.db.query("SELECT id, did, type, queue, due, usn FROM cards WHERE usn = -1 ORDER BY id") { stmt in
            result.append([
                "id": sqlite3_column_int64(stmt, 0),
                "did": sqlite3_column_int64(stmt, 1),
                "type": Int(sqlite3_column_int(stmt, 2)),
                "queue": Int(sqlite3_column_int(stmt, 3)),
                "due": Int(sqlite3_column_int(stmt, 4)),
                "usn": Int(sqlite3_column_int(stmt, 5))
            ])
        }
        return result
    }

    static func tagActions(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard let action = args.first else { throw SQLiteError.exec("tag-actions <add-existing|add-new|remove-missing|remove-parent|replace-missing|replace-parent>") }
        let noteID = try store.db.scalarInt64("SELECT id FROM notes WHERE tags LIKE '%animal%' ORDER BY id LIMIT 1")
        try store.db.run("UPDATE notes SET usn = 42 WHERE id = ?") { SQLiteDatabase.bindInt64($0, 1, noteID) }
        switch action {
        case "add-existing": try store.addTag(to: [noteID], tag: "animal")
        case "add-new": try store.addTag(to: [noteID], tag: "newTag child::tag")
        case "remove-missing": try store.removeTag(from: [noteID], tag: "unknown")
        case "remove-parent": try store.removeTag(from: [noteID], tag: "animal")
        case "replace-missing": try store.replaceTag(in: [noteID], from: "unknown", to: "pet")
        case "replace-parent": try store.replaceTag(in: [noteID], from: "animal", to: "pet")
        default: throw SQLiteError.exec("Unsupported tag action")
        }
        guard let note = try store.fetchNote(id: noteID) else { throw SQLiteError.exec("Fixture note was not found") }
        return ["tags": note.tags, "usn": note.usn]
    }

    static func notetypeActions(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard let action = args.first else { throw SQLiteError.exec("notetype-actions <add-basic-reverse|basic-reverse|reverse-basic|basic-cloze|cloze-basic>") }
        let noteID: Int64
        var originalCardIDs: [Int64] = []
        if action == "add-basic-reverse" {
            guard let model = store.notetypes.first(where: { $0.name == "Basic (and reversed card)" }) else {
                throw SQLiteError.exec("Fixture note type was not found")
            }
            try store.addNote(mid: model.id, did: 1, fields: ["Parity front", "Parity back"], tags: "")
            noteID = try store.db.scalarInt64("SELECT id FROM notes WHERE mid = ? AND flds = ? ORDER BY id DESC LIMIT 1", bind: { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, model.id)
                try SQLiteDatabase.bindText(stmt, 2, "Parity front\u{1f}Parity back")
            })
        } else {
            let sourceName: String
            let targetName: String
            switch action {
            case "basic-reverse": sourceName = "Basic"; targetName = "Basic (and reversed card)"
            case "reverse-basic": sourceName = "Basic (and reversed card)"; targetName = "Basic"
            case "basic-cloze": sourceName = "Basic"; targetName = "Cloze"
            case "cloze-basic": sourceName = "Cloze"; targetName = "Basic"
            default: throw SQLiteError.exec("Unsupported note type action")
            }
            guard let source = store.notetypes.first(where: { $0.name == sourceName }),
                  let target = store.notetypes.first(where: { $0.name == targetName }) else {
                throw SQLiteError.exec("Fixture note type was not found")
            }
            if action == "cloze-basic" {
                try store.addNote(mid: source.id, did: store.decks.first(where: { $0.name == "Math" })?.id ?? 1, fields: ["{{c1::one}} {{c2::two}}", "extra"], tags: "", guid: "parity-cloze-type")
                noteID = try store.db.scalarInt64("SELECT id FROM notes WHERE guid = ?") { try SQLiteDatabase.bindText($0, 1, "parity-cloze-type") }
            } else {
                noteID = try store.db.scalarInt64("SELECT id FROM notes WHERE mid = ? ORDER BY id LIMIT 1") {
                    SQLiteDatabase.bindInt64($0, 1, source.id)
                }
            }
            try store.db.run("UPDATE notes SET usn = 42 WHERE id = ?") { SQLiteDatabase.bindInt64($0, 1, noteID) }
            try store.db.run("UPDATE cards SET usn = 43 WHERE nid = ?") { SQLiteDatabase.bindInt64($0, 1, noteID) }
            try store.db.query("SELECT id FROM cards WHERE nid = ? ORDER BY id", bind: {
                SQLiteDatabase.bindInt64($0, 1, noteID)
            }) { stmt in originalCardIDs.append(sqlite3_column_int64(stmt, 0)) }
            try store.changeNoteType(noteIDs: [noteID], to: target.id)
        }
        guard let note = try store.fetchNote(id: noteID) else { throw SQLiteError.exec("Fixture note was not found") }
        var cards: [[String: Any]] = []
        try store.db.query("SELECT ord, type, queue, due, ivl, factor, reps, lapses, usn FROM cards WHERE nid = ? ORDER BY ord", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) { stmt in
            cards.append([
                "ord": Int(sqlite3_column_int(stmt, 0)),
                "type": Int(sqlite3_column_int(stmt, 1)),
                "queue": Int(sqlite3_column_int(stmt, 2)),
                "due": Int(sqlite3_column_int(stmt, 3)),
                "ivl": Int(sqlite3_column_int(stmt, 4)),
                "factor": Int(sqlite3_column_int(stmt, 5)),
                "reps": Int(sqlite3_column_int(stmt, 6)),
                "lapses": Int(sqlite3_column_int(stmt, 7)),
                "usn": Int(sqlite3_column_int(stmt, 8))
            ])
        }
        let graveCount: Int
        if originalCardIDs.isEmpty {
            graveCount = 0
        } else {
            let placeholders = originalCardIDs.map { _ in "?" }.joined(separator: ",")
            graveCount = try store.db.scalarInt("SELECT COUNT(*) FROM graves WHERE type = 0 AND oid IN (\(placeholders))") { stmt in
                for (index, id) in originalCardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }
        }
        return [
            "note": ["mid": note.mid, "fields": note.flds, "tags": note.tags, "usn": note.usn],
            "cards": cards,
            "removedCards": graveCount
        ]
    }

    static func notetypeDeleteActions(_ store: CollectionStore) throws -> [String: Any] {
        guard let notetype = store.notetypes.first(where: { $0.name == "Basic (and reversed card)" }) else {
            throw SQLiteError.exec("Fixture note type was not found")
        }
        var noteIDs: [Int64] = []
        try store.db.query("SELECT id FROM notes WHERE mid = ? ORDER BY id", bind: {
            SQLiteDatabase.bindInt64($0, 1, notetype.id)
        }) { stmt in noteIDs.append(sqlite3_column_int64(stmt, 0)) }
        guard !noteIDs.isEmpty else { throw SQLiteError.exec("Fixture note type has no notes") }

        var cardIDs: [Int64] = []
        let notePlaceholders = noteIDs.map { _ in "?" }.joined(separator: ",")
        try store.db.query("SELECT id FROM cards WHERE nid IN (\(notePlaceholders)) ORDER BY id", bind: { stmt in
            for (index, id) in noteIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
        }) { stmt in cardIDs.append(sqlite3_column_int64(stmt, 0)) }
        guard let cardID = cardIDs.first else { throw SQLiteError.exec("Fixture note type has no cards") }
        let revlogID = try store.db.scalarInt64("SELECT COALESCE(MAX(id), 0) + 1 FROM revlog")
        try store.db.run("INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) VALUES (?, ?, -1, 3, 3, 1, 2500, 6000, 1)") { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, revlogID)
            SQLiteDatabase.bindInt64(stmt, 2, cardID)
        }
        var updatedConf = store.conf
        updatedConf["curModel"] = notetype.id
        updatedConf["_nt_\(notetype.id)_lastDeckAddedTo"] = 1
        var rememberedDecks = updatedConf["lastDeckByNoteType"] as? [String: Any] ?? [:]
        rememberedDecks[String(notetype.id)] = 1
        updatedConf["lastDeckByNoteType"] = rememberedDecks
        try store.saveConf(updatedConf)

        func configID(_ value: Any?) -> Int64? {
            if let number = value as? NSNumber { return number.int64Value }
            if let value = value as? Int64 { return value }
            if let value = value as? Int { return Int64(value) }
            return nil
        }

        func snapshot() throws -> [String: Any] {
            let modelNames = store.notetypes.map(\.name).sorted()
            let currentModel = configID(store.conf["curModel"]).flatMap { store.notetype(id: $0)?.name }
            let currentAuxKey = "_nt_\(notetype.id)_lastDeckAddedTo"
            let remembered = store.conf["lastDeckByNoteType"] as? [String: Any] ?? [:]
            let cardPlaceholders = cardIDs.map { _ in "?" }.joined(separator: ",")
            let noteGraves = try store.db.scalarInt("SELECT COUNT(*) FROM graves WHERE type = 1 AND oid IN (\(notePlaceholders))") { stmt in
                for (index, id) in noteIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }
            let cardGraves = try store.db.scalarInt("SELECT COUNT(*) FROM graves WHERE type = 0 AND oid IN (\(cardPlaceholders))") { stmt in
                for (index, id) in cardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }
            let revlogs = try store.db.scalarInt("SELECT COUNT(*) FROM revlog WHERE cid IN (\(cardPlaceholders))") { stmt in
                for (index, id) in cardIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }
            return [
                "notetypes": modelNames,
                "notes": try store.db.scalarInt("SELECT COUNT(*) FROM notes WHERE mid = ?", bind: { SQLiteDatabase.bindInt64($0, 1, notetype.id) }),
                "cards": try store.db.scalarInt("SELECT COUNT(*) FROM cards WHERE nid IN (\(notePlaceholders))", bind: { stmt in
                    for (index, id) in noteIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                }),
                "noteGraves": noteGraves,
                "cardGraves": cardGraves,
                "revlogs": revlogs,
                "currentModel": currentModel as Any? ?? NSNull(),
                "auxiliaryConfigPresent": store.conf[currentAuxKey] != nil,
                "rememberedDeckPresent": remembered[String(notetype.id)] != nil
            ]
        }

        let before = try snapshot()
        try store.deleteNotetypeUndoably(id: notetype.id)
        let after = try snapshot()
        try store.undoMostRecentCollectionAction()
        let undone = try snapshot()
        try store.redoMostRecentCollectionAction()
        let redone = try snapshot()
        return ["before": before, "after": after, "undone": undone, "redone": redone]
    }

    static func templateRender(args: [String]) throws -> [String: String] {
        guard let expression = args.first, let value = args.dropFirst().first else {
            throw SQLiteError.exec("template-render <filter:Field> <value>")
        }
        return ["rendered": TemplateEngine.render(
            template: "{{\(expression)}}",
            fields: ["Front": value],
            questionSide: true
        )]
    }

    static func templateRenderBatch(args: [String]) throws -> [String] {
        guard let input = args.first?.data(using: .utf8) else {
            throw SQLiteError.exec("template-render-batch <json-cases>")
        }
        let cases = try JSONDecoder().decode([[String]].self, from: input)
        return try cases.map { item in
            guard item.count == 2 else { throw SQLiteError.exec("Expected an expression and field value") }
            return try templateRender(args: item)["rendered"] ?? ""
        }
    }

    static func cardRenderBatch(_ store: CollectionStore, args: [String], modelName: String = "Basic") throws -> [String] {
        guard let input = args.first?.data(using: .utf8),
              var model = store.notetypes.first(where: { $0.name == modelName }),
              let row = try store.search(query: "note:\(modelName)", limit: 1).first,
              var note = try store.fetchNote(id: row.card.nid) else {
            throw SQLiteError.exec("card-render-batch <json-templates>")
        }
        note.flds = "PARITY_HIDDEN_FIELD\u{1f}"
        var card = row.card
        card.ord = 0
        let templates = try JSONDecoder().decode([String].self, from: input)
        return templates.map { template in
            model.tmpls[0].qfmt = template
            let rendered = CardHTMLRenderer.renderCard(
                note: note, card: card, notetype: model, side: .question,
                mediaBase: URL(fileURLWithPath: "/tmp")
            )
            let opening = "<div class=\"card\">\n"
            guard let start = rendered.html.range(of: opening),
                  let end = rendered.html.range(of: "\n</div>", range: start.upperBound..<rendered.html.endIndex) else {
                return rendered.html
            }
            return String(rendered.html[start.upperBound..<end.lowerBound])
        }
    }

    static func latexExtract(args: [String]) throws -> [String: Any] {
        guard let text = args.first else { throw SQLiteError.exec("latex-extract <text> [--svg]") }
        let extraction = AnkiLatexMarkup.extract(
            in: text,
            svg: args.contains("--svg"),
            expandClozes: args.contains("--expand-clozes")
        )
        return [
            "html": extraction.html,
            "assets": extraction.assets.map { ["filename": $0.filename, "body": $0.body] }
        ]
    }

    static func latexGenerate(args: [String]) throws -> [String: Any] {
        guard let path = args.first else { throw SQLiteError.exec("latex-generate <media-directory> [--svg]") }
        let svg = args.contains("--svg")
        let filename = svg ? "latex-parity.svg" : "latex-parity.png"
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let task = AnkiLatexRenderTask(
            asset: AnkiLatexAsset(filename: filename, body: "E=mc^2"),
            header: AnkiNotetype.defaultLatexPre,
            footer: AnkiNotetype.defaultLatexPost,
            svg: svg
        )
        let errors = AnkiLatexImageGenerator.renderMissing([task], mediaRoot: root, enabled: true)
        let output = root.appendingPathComponent(filename)
        let data = try? Data(contentsOf: output)
        return ["errors": errors, "exists": data != nil, "size": data?.count ?? 0]
    }

    static func search(_ store: CollectionStore, args: [String]) throws -> [Int64] {
        let query = args.joined(separator: " ")
        return try store.search(query: query, limit: 10_000).map(\.id).sorted()
    }

    static func searchBatch(_ store: CollectionStore, args: [String]) throws -> [String: [Int64]] {
        guard let input = args.first?.data(using: .utf8) else {
            throw SQLiteError.exec("search-batch <json-queries>")
        }
        let queries = try JSONDecoder().decode([String].self, from: input)
        var results: [String: [Int64]] = [:]
        for query in queries {
            results[query] = try search(store, args: [query])
        }
        return results
    }

    static func retention(_ store: CollectionStore) throws -> [[String: Int]] {
        try store.trueRetention().map { period in
            [
                "youngPass": period.youngPass,
                "youngFail": period.youngFail,
                "maturePass": period.maturePass,
                "matureFail": period.matureFail
            ]
        }
    }

    static func stats(_ store: CollectionStore) throws -> [String: Any] {
        let today = try store.statsTodaySummary()
        let collection = try store.statsCollectionCounts()
        let reviewMonth = try store.reviewsByType(buckets: 31, chunkDays: 1)
        let reviewYear = try store.reviewsByType(buckets: 52, chunkDays: 7)
        let addedMonth = try store.cardsAdded(buckets: 31, chunkDays: 1)
        let addedYear = try store.cardsAdded(buckets: 52, chunkDays: 7)
        let dueMonth = try store.futureDue(buckets: 31, chunkDays: 1)
        let futureDueForecast = try store.futureDueForecast(buckets: nil, chunkDays: 1)
        let intervalMonth = try store.intervalStatistics(days: 31, historyDays: try store.reviewHistoryDays())
        let buttonsMonth = try store.answerButtonBreakdown(days: 31)
        let stringKeyed: ([Int: Int]) -> [String: Int] = { values in
            Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })
        }
        let reviewPoint: (CollectionStore.ReviewDayPoint) -> [String: Int] = { point in
            [
                "offset": point.offset,
                "learn": point.learn,
                "young": point.young,
                "mature": point.mature,
                "relearn": point.relearn,
                "filtered": point.filtered,
                "timeMS": point.timeMS
            ]
        }
        return [
            "today": [
                "reviews": today.reviews,
                "timeMS": today.timeMS,
                "failed": today.failed,
                "learning": today.learning,
                "review": today.review,
                "relearning": today.relearning,
                "filtered": today.filtered,
                "matureCorrect": today.matureCorrect,
                "matureTotal": today.matureTotal
            ],
            "collection": ["notes": collection.notes, "cards": collection.cards],
            "reviewHistoryDays": try store.reviewHistoryDays(),
            "reviewMonth": reviewMonth.map(reviewPoint),
            "reviewYear": reviewYear.map(reviewPoint),
            "addedMonth": stringKeyed(addedMonth),
            "addedYear": stringKeyed(addedYear),
            "dueMonth": stringKeyed(dueMonth),
            "futureDueForecast": [
                "dueByDay": stringKeyed(futureDueForecast.dueByDay),
                "dailyLoad": futureDueForecast.dailyLoad,
                "hasBacklog": futureDueForecast.hasBacklog
            ],
            "intervalMonth": [
                "points": intervalMonth.points.map { ["bucket": $0.bucket, "count": $0.count] },
                "averageDays": intervalMonth.averageDays ?? -1,
                "longestDays": intervalMonth.longestDays ?? -1,
                "totalCards": intervalMonth.totalCards
            ],
            "buttonsMonth": buttonsMonth.map { [
                "category": $0.category,
                "again": $0.again,
                "hard": $0.hard,
                "good": $0.good,
                "easy": $0.easy
            ] }
        ]
    }

    static func timing(_ store: CollectionStore) -> [String: Any] {
        ["days": store.schedDay(), "nextDayAt": store.schedDayStartTimestamp() + 86_400]
    }

    static func counts(_ store: CollectionStore) -> [String: Any] {
        var out: [String: Any] = [:]
        for deck in store.decks {
            let c = store.deckCounts[deck.id] ?? DeckCounts(new: 0, learn: 0, review: 0)
            out[String(deck.id)] = [c.new, c.learn, c.review]
        }
        return out
    }

    static func cardState(_ card: AnkiCard, now: Int) -> [String: Any] {
        let intraday = card.queue == 1 || card.queue == 4
        return [
            "type": card.type, "queue": card.queue,
            "due": intraday ? card.due - now : card.due,
            "ivl": card.ivl, "factor": card.factor, "reps": card.reps,
            "lapses": card.lapses, "left": card.left,
            "odue": card.odue, "odid": card.odid, "did": card.did,
        ]
    }

    static func states(_ store: CollectionStore, ids: [Int64]) throws -> [String: Any] {
        let scheduler = Scheduler(store: store)
        var cardIDs = ids
        if cardIDs.isEmpty {
            try store.db.query("SELECT id FROM cards WHERE queue >= 0 ORDER BY id") { stmt in
                cardIDs.append(sqlite3_column_int64(stmt, 0))
            }
        }
        let now = Int(Date().timeIntervalSince1970)
        var out: [String: Any] = [:]
        for id in cardIDs {
            guard let card = try store.fetchCard(id: id), let deck = store.deck(id: card.did) else { continue }
            let results = scheduler.harnessResults(card: card, deck: deck)
            var entry: [String: Any] = [:]
            entry["labels"] = Rating.allCases.map { results[$0]?.intervalLabel ?? "" }
            for rating in Rating.allCases {
                guard let result = results[rating] else { continue }
                var state = cardState(result.card, now: now)
                state["revlogIvl"] = result.revlogIvl
                state["revlogLastIvl"] = result.lastIvl
                state["revlogFactor"] = result.revlogFactor
                entry[String(rating.rawValue)] = state
            }
            out[String(id)] = entry
        }
        return out
    }

    /// `session [deckName] [limit]`: study the named deck (default Lang) and answer
    /// cards with a fixed rating script, recording order and counts.
    static func session(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        let name = args.first.flatMap { $0.isEmpty || Int($0) != nil ? nil : $0 } ?? "Lang"
        let limit = args.compactMap(Int.init).last ?? 20
        guard let deck = store.decks.first(where: { $0.name == name }) else {
            throw SQLiteError.exec("deck \(name) not found")
        }
        store.setCurrentDeck(deck.id)
        let scheduler = store.schedulerForStudySession()
        let ratings: [Rating] = [.good, .good, .again, .hard, .easy, .good, .again, .good, .hard, .good]
        var steps: [[String: Any]] = []
        for i in 0..<limit {
            let queued = try store.queuedStudyCards(for: deck.id)
            let counts = [queued.counts.new, queued.counts.learning, queued.counts.review]
            guard let card = queued.cards.first, let live = store.deck(id: card.did) ?? store.deck(id: deck.id) else {
                steps.append(["id": 0, "counts": counts, "rating": 0])
                break
            }
            let rating = ratings[i % ratings.count]
            try scheduler.answer(card: card, deck: live, rating: rating, timeTakenMS: 5_000)
            steps.append(["id": card.id, "counts": counts, "rating": rating.rawValue])
        }
        let final = try store.queuedStudyCards(for: deck.id).counts
        return [
            "deck": deck.id,
            "steps": steps,
            "finalCounts": [final.new, final.learning, final.review]
        ]
    }

    /// `answer <cid> <rating>`: answers one card and prints the stored result.
    static func answer(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard args.count >= 2, let id = Int64(args[0]), let raw = Int(args[1]), let rating = Rating(rawValue: raw),
              let card = try store.fetchCard(id: id), let deck = store.deck(id: card.did) else {
            throw SQLiteError.exec("answer <cid> <rating>")
        }
        let scheduler = Scheduler(store: store)
        try scheduler.answer(card: card, deck: deck, rating: rating, timeTakenMS: 5_000)
        let now = Int(Date().timeIntervalSince1970)
        guard let after = try store.fetchCard(id: id) else { return [:] }
        return cardState(after, now: now)
    }

    static func gradeNow(_ store: CollectionStore, args: [String]) throws -> [String: Any] {
        guard args.count >= 2,
              let ratingValue = Int(args[1]),
              let rating = Rating(rawValue: ratingValue) else {
            throw SQLiteError.exec("grade-now <comma-separated-card-ids> <rating>")
        }
        let cardIDs = args[0].split(separator: ",").compactMap { Int64($0) }
        guard !cardIDs.isEmpty else { throw SQLiteError.exec("No cards were selected") }
        let scheduler = store.schedulerForStudySession()

        func snapshot() throws -> [String: Any] {
            var cards: [[String: Any]] = []
            var revlogs: [[String: Any]] = []
            var noteIDs = Set<Int64>()
            for id in cardIDs {
                guard let card = try store.fetchCard(id: id) else { continue }
                noteIDs.insert(card.nid)
                cards.append([
                    "id": card.id,
                    "type": card.type,
                    "queue": card.queue,
                    "due": card.due,
                    "ivl": card.ivl,
                    "factor": card.factor,
                    "reps": card.reps,
                    "lapses": card.lapses,
                    "left": card.left,
                    "odue": card.odue,
                    "odid": card.odid,
                    "did": card.did,
                    "flags": card.flags,
                    "data": card.data
                ])
                try store.db.query("SELECT ease, ivl, lastIvl, factor, time, type FROM revlog WHERE cid = ? ORDER BY id DESC LIMIT 1", bind: {
                    SQLiteDatabase.bindInt64($0, 1, id)
                }) { stmt in
                    revlogs.append([
                        "cid": id,
                        "ease": sqlite3_column_int(stmt, 0),
                        "ivl": sqlite3_column_int(stmt, 1),
                        "lastIvl": sqlite3_column_int(stmt, 2),
                        "factor": sqlite3_column_int(stmt, 3),
                        "time": sqlite3_column_int(stmt, 4),
                        "type": sqlite3_column_int(stmt, 5)
                    ])
                }
            }
            var notes: [[String: Any]] = []
            for id in noteIDs.sorted() {
                if let note = try store.fetchNote(id: id) {
                    notes.append(["id": note.id, "tags": note.tags])
                }
            }
            let decks = store.decks.sorted { $0.id < $1.id }.map { deck in
                [
                    "id": deck.id,
                    "newToday": deck.newToday,
                    "revToday": deck.revToday,
                    "lrnToday": deck.lrnToday,
                    "timeToday": deck.timeToday
                ] as [String: Any]
            }
            return ["cards": cards, "revlogs": revlogs, "notes": notes, "decks": decks]
        }

        try scheduler.gradeNow(cardIDs: cardIDs, rating: rating)
        let after = try snapshot()
        try store.undoMostRecentCollectionAction()
        let undone = try snapshot()
        try store.redoMostRecentCollectionAction()
        let redone = try snapshot()
        return ["after": after, "undone": undone, "redone": redone]
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
