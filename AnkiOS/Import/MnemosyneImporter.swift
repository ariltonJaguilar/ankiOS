import Foundation
import SQLite3
import UniformTypeIdentifiers

extension UTType {
    static let mnemosyneDB = UTType(filenameExtension: "db") ?? .data
}

enum MnemosyneImportError: Error, LocalizedError {
    case open(String)
    case invalidCollection
    case unsupportedFactView(String)
    case missingNote(Int64)
    case emptyCollection

    var errorDescription: String? {
        switch self {
        case .open(let message): "Não foi possível abrir a coleção Mnemosyne: \(message)"
        case .invalidCollection: "O arquivo não contém uma coleção Mnemosyne compatível."
        case .unsupportedFactView(let view): "O tipo de cartão Mnemosyne ‘\(view)’ não é compatível."
        case .missingNote(let id): "A nota Mnemosyne \(id) não contém os dados esperados."
        case .emptyCollection: "A coleção Mnemosyne não contém notas para importar."
        }
    }
}

@MainActor
final class MnemosyneImporter {
    private enum FactView: Hashable {
        case frontOnly
        case frontBack
        case vocabulary
        case cloze

        var name: String {
            switch self {
            case .frontOnly: "Mnemosyne-FrontOnly"
            case .frontBack: "Mnemosyne-FrontBack"
            case .vocabulary: "Mnemosyne-Vocabulary"
            case .cloze: "Mnemosyne-Cloze"
            }
        }

        var fields: [String] {
            switch self {
            case .frontOnly, .frontBack: ["Front", "Back"]
            case .vocabulary: ["Expression", "Pronunciation", "Meaning", "Notes"]
            case .cloze: ["Text"]
            }
        }

        var sourceFields: [String] {
            switch self {
            case .frontOnly, .frontBack: ["f", "b"]
            case .vocabulary: ["f", "p_1", "m_1", "n"]
            case .cloze: ["text"]
            }
        }

        var templates: [AnkiTemplate] {
            switch self {
            case .frontOnly:
                [AnkiTemplate(name: "Card 1", ord: 0, qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr id=answer>{{Back}}")]
            case .frontBack:
                [
                    AnkiTemplate(name: "Card 1", ord: 0, qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr id=answer>{{Back}}"),
                    AnkiTemplate(name: "Card 2", ord: 1, qfmt: "{{Back}}", afmt: "{{FrontSide}}<hr id=answer>{{Front}}")
                ]
            case .vocabulary:
                [
                    AnkiTemplate(name: "Recognition", ord: 0, qfmt: "{{Expression}}", afmt: "{{Expression}}<hr id=answer>{{Pronunciation}}<br>{{Meaning}}<br>{{Notes}}"),
                    AnkiTemplate(name: "Production", ord: 1, qfmt: "{{Meaning}}", afmt: "{{Meaning}}<hr id=answer>{{Expression}}<br>{{Pronunciation}}<br>{{Notes}}")
                ]
            case .cloze:
                [AnkiTemplate(name: "Cloze", ord: 0, qfmt: "{{cloze:Text}}", afmt: "{{cloze:Text}}")]
            }
        }

        var type: Int { self == .cloze ? 1 : 0 }

        init(factViewID: String) throws {
            if factViewID.hasPrefix("1.") || factViewID.hasPrefix("1::") { self = .frontOnly }
            else if factViewID.hasPrefix("2.") || factViewID.hasPrefix("2::") { self = .frontBack }
            else if factViewID.hasPrefix("3.") || factViewID.hasPrefix("3::") { self = .vocabulary }
            else if factViewID.hasPrefix("5.1") { self = .cloze }
            else { throw MnemosyneImportError.unsupportedFactView(factViewID) }
        }
    }

    private struct MnemoCard {
        var factViewID: String
        var tags: String
        var nextRep: Int64
        var lastRep: Int64
        var ease: Double
        var reps: Int
        var lapses: Int

        var ordinal: Int? {
            let suffix = factViewID.components(separatedBy: CharacterSet(charactersIn: ".:")).last ?? ""
            guard let index = Int(suffix) else { return nil }
            return max(0, index - 1)
        }
    }

    private struct Fact {
        var id: Int64
        var fields: [String: String] = [:]
        var cards: [MnemoCard] = []
    }

    private let store: CollectionStore

    init(store: CollectionStore) {
        self.store = store
    }

    func importFile(at url: URL) throws -> String {
        let source = try ReadOnlySQLiteDatabase(path: url.path)
        try validate(source)
        let facts = try readFacts(from: source)
        guard !facts.isEmpty else { throw MnemosyneImportError.emptyCollection }

        let deck = store.decks.first(where: { !$0.isFiltered && $0.name == "Default" })
            ?? store.decks.first(where: { !$0.isFiltered })
        guard let deck else { throw SQLiteError.exec("Nenhum baralho disponível para importar.") }

        let factViews = try Dictionary(uniqueKeysWithValues: facts.map { ($0.id, try factView(for: $0)) })
        let types = try ensureNotetypes(for: Set(factViews.values))
        let dayStart = store.schedDayStartTimestamp() - Int64(store.schedDay()) * 86_400
        var importedCards = 0

        try store.db.exec("BEGIN IMMEDIATE")
        do {
            for fact in facts {
                guard let view = factViews[fact.id], let notetype = types[view] else {
                    throw MnemosyneImportError.missingNote(fact.id)
                }
                let fields = view.sourceFields.map { munge(fact.fields[$0] ?? "") }
                let tags = normalizedTags(fact.cards.flatMap { $0.tags.components(separatedBy: ", ") })
                let guid = "mnemosyne-\(fact.id)-\(UUID().uuidString)"
                try store.addNote(mid: notetype.id, did: deck.id, fields: fields, tags: tags.joined(separator: " "), guid: guid)

                guard let note = try store.fetchNote(guid: guid) else { throw MnemosyneImportError.missingNote(fact.id) }
                var cardsByOrdinal: [Int: Int64] = [:]
                try store.db.query("SELECT id, ord FROM cards WHERE nid = ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, note.id)
                }) { statement in
                    cardsByOrdinal[Int(sqlite3_column_int(statement, 1))] = sqlite3_column_int64(statement, 0)
                }

                for sourceCard in fact.cards where sourceCard.lastRep != -1 {
                    guard let ordinal = sourceCard.ordinal, let cardID = cardsByOrdinal[ordinal] else { continue }
                    let interval = max(1, Int((sourceCard.nextRep - sourceCard.lastRep) / 86_400))
                    let dueDay = Int(floor(Double(sourceCard.nextRep - dayStart) / 86_400.0))
                    _ = try store.db.run("""
                        UPDATE cards SET type=2, queue=2, due=?, ivl=?, factor=?, reps=?, lapses=?, mod=?, usn=-1
                        WHERE id=?
                    """) { statement in
                        SQLiteDatabase.bindInt(statement, 1, dueDay)
                        SQLiteDatabase.bindInt(statement, 2, interval)
                        SQLiteDatabase.bindInt(statement, 3, max(1300, Int((sourceCard.ease * 1000).rounded())))
                        SQLiteDatabase.bindInt(statement, 4, sourceCard.reps)
                        SQLiteDatabase.bindInt(statement, 5, sourceCard.lapses)
                        SQLiteDatabase.bindInt64(statement, 6, Int64(Date().timeIntervalSince1970))
                        SQLiteDatabase.bindInt64(statement, 7, cardID)
                    }
                    importedCards += 1
                }
            }
            try store.db.exec("COMMIT")
        } catch {
            try? store.db.exec("ROLLBACK")
            throw error
        }

        try store.reloadMeta()
        try store.refreshCounts()
        return "Importadas \(facts.count) notas e \(importedCards) cartões agendados do Mnemosyne."
    }

    private func validate(_ source: ReadOnlySQLiteDatabase) throws {
        let required = ["global_variables", "facts", "data_for_fact", "cards"]
        for table in required where try !source.tableExists(table) {
            throw MnemosyneImportError.invalidCollection
        }
    }

    private func readFacts(from source: ReadOnlySQLiteDatabase) throws -> [Fact] {
        var facts: [Int64: Fact] = [:]
        try source.query("SELECT facts._id, data_for_fact.key, data_for_fact.value FROM facts JOIN data_for_fact ON facts._id=data_for_fact._fact_id") { statement in
            let id = sqlite3_column_int64(statement, 0)
            var fact = facts[id] ?? Fact(id: id)
            fact.fields[ReadOnlySQLiteDatabase.text(statement, 1)] = ReadOnlySQLiteDatabase.text(statement, 2)
            facts[id] = fact
        }
        try source.query("SELECT _fact_id, fact_view_id, tags, next_rep, last_rep, easiness, acq_reps + ret_reps, lapses FROM cards ORDER BY _fact_id, fact_view_id") { statement in
            let id = sqlite3_column_int64(statement, 0)
            guard var fact = facts[id] else { throw MnemosyneImportError.missingNote(id) }
            fact.cards.append(MnemoCard(
                factViewID: ReadOnlySQLiteDatabase.text(statement, 1),
                tags: ReadOnlySQLiteDatabase.text(statement, 2),
                nextRep: sqlite3_column_int64(statement, 3),
                lastRep: sqlite3_column_int64(statement, 4),
                ease: sqlite3_column_double(statement, 5),
                reps: Int(sqlite3_column_int(statement, 6)),
                lapses: Int(sqlite3_column_int(statement, 7))
            ))
            facts[id] = fact
        }
        return facts.values.sorted { $0.id < $1.id }
    }

    private func factView(for fact: Fact) throws -> FactView {
        guard let first = fact.cards.first else { return .frontOnly }
        return try FactView(factViewID: first.factViewID)
    }

    private func ensureNotetypes(for views: Set<FactView>) throws -> [FactView: AnkiNotetype] {
        var types = store.notetypes
        var result: [FactView: AnkiNotetype] = [:]
        for view in views.sorted(by: { $0.name < $1.name }) {
            let templateQuestions = view.templates.map(\.qfmt)
            let existing = types.first { notetype in
                guard notetype.name == view.name, notetype.type == view.type else { return false }
                let fieldNames = notetype.flds.sorted { $0.ord < $1.ord }.map(\.name)
                let questions = notetype.tmpls.sorted { $0.ord < $1.ord }.map(\.qfmt)
                return fieldNames == view.fields && questions == templateQuestions
            }
            if let existing {
                result[view] = existing
                continue
            }
            let name = types.contains(where: { $0.name == view.name }) ? "\(view.name) imported" : view.name
            let id = store.timestampID()
            let notetype = AnkiNotetype(
                id: id,
                name: name,
                type: view.type,
                mod: Int64(Date().timeIntervalSince1970),
                tmpls: view.templates,
                flds: view.fields.enumerated().map { AnkiField(name: $0.element, ord: $0.offset) }
            )
            types.append(notetype)
            result[view] = notetype
        }
        try store.saveNotetypes(types)
        return result
    }

    private func normalizedTags(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "\u{3000}", with: "_") }.filter { !$0.isEmpty })).sorted()
    }

    private func munge(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
        if let latexRegex = try? NSRegularExpression(pattern: #"<(/?(?:\$\$?|latex))>"#, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..., in: result)
            result = latexRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[$1]")
        }
        if let regex = try? NSRegularExpression(pattern: #"<audio src="(.+?)">(?:</audio>)?"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[sound:$1]")
        }
        return result
    }
}

private final class ReadOnlySQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(result)"
            if let handle { sqlite3_close(handle) }
            throw MnemosyneImportError.open(message)
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func tableExists(_ name: String) throws -> Bool {
        var exists = false
        try query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", bind: { statement in
            try SQLiteDatabase.bindText(statement, 1, name)
        }) { _ in
            exists = true
        }
        return exists
    }

    func query(_ sql: String, bind: ((OpaquePointer) throws -> Void)? = nil, map: (OpaquePointer) throws -> Void) throws {
        guard let handle else { throw MnemosyneImportError.open("Banco fechado") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MnemosyneImportError.open(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind?(statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw MnemosyneImportError.open(String(cString: sqlite3_errmsg(handle))) }
            try map(statement)
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}
