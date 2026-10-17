import Foundation
import SQLite3

private indirect enum CardGenerationNode {
    case replacement(String)
    case conditional(String, [CardGenerationNode])
    case negated(String, [CardGenerationNode])
}

extension CollectionStore {
    /// Regenerate cards for one note after its notetype or cloze field content changed.
    func regenerateCards(forNoteID noteID: Int64) throws {
        guard let note = try fetchNote(id: noteID),
              let model = notetype(id: note.mid) else { return }
        try regenerateCards(
            forNoteID: noteID,
            model: model,
            fields: note.fields,
            tags: note.tagList
        )
    }

    private func regenerateCards(
        forNoteID noteID: Int64,
        model: AnkiNotetype,
        fields: [String],
        tags: [String]
    ) throws {
        if model.isCloze {
            let wanted = Set(ClozeHelper.ords(in: fields))
            try syncNoteCards(
                noteID: noteID,
                wanted: wanted
            )
        } else {
            let wanted = Set(activeTemplateOrds(model: model, fields: fields, tags: tags))
            try syncNoteCards(
                noteID: noteID,
                wanted: wanted
            )
        }
    }

    func activeTemplateOrds(model: AnkiNotetype, fields: [String], tags: [String] = []) -> [Int] {
        var nonemptyFields = Set<String>()
        for field in model.flds {
            let value = field.ord < fields.count ? fields[field.ord] : ""
            if !Self.ankiFieldIsEmpty(value) { nonemptyFields.insert(field.name) }
        }
        let noteFieldNames = Set(model.flds.map(\.name))
        for specialField in ["Card", "CardFlag", "Deck", "Subdeck", "Tags", "Type", "CardID"] {
            if !noteFieldNames.contains(specialField), specialField != "Tags" || !tags.isEmpty {
                nonemptyFields.insert(specialField)
            }
        }
        var knownFields = noteFieldNames
        knownFields.formUnion(["Card", "CardFlag", "Deck", "Subdeck", "Tags", "Type", "CardID", "FrontSide"])

        return model.tmpls.compactMap { tmpl in
            Self.templateRendersWithFields(tmpl.qfmt, nonemptyFields: nonemptyFields, knownFields: knownFields) ? tmpl.ord : nil
        }
    }

    static func ankiFieldIsEmpty(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)^(?:\s|</?(?:br|div)\s?/?>)*$"#) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    static func templateRendersWithFields(
        _ template: String,
        nonemptyFields: Set<String>,
        knownFields: Set<String>
    ) -> Bool {
        let source = TemplateEngine.removingHTMLComments(from: TemplateEngine.normalizedTemplateSyntax(template))
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([^}]+)\}\}"#) else { return false }
        let sourceRange = NSRange(source.startIndex..., in: source)
        let handles = regex.matches(in: source, range: sourceRange).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var index = 0

        func fieldName(_ handle: String) -> String {
            handle.split(separator: ":").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? handle
        }

        func parse(_ closing: String? = nil) -> ([CardGenerationNode], Bool) {
            var nodes: [CardGenerationNode] = []
            while index < handles.count {
                let handle = handles[index]
                index += 1
                if handle.hasPrefix("!") { continue }
                if handle.hasPrefix("/") {
                    return (nodes, closing == String(handle.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if handle.hasPrefix("#") || handle.hasPrefix("^") {
                    let name = String(handle.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    let (children, closed) = parse(name)
                    guard closed else { return (nodes, false) }
                    if handle.hasPrefix("#") { nodes.append(.conditional(name, children)) }
                    else { nodes.append(.negated(name, children)) }
                    continue
                }
                if handle.hasPrefix("=") { continue }
                let name = fieldName(handle)
                guard !name.isEmpty else { continue }
                nodes.append(.replacement(name))
            }
            return (nodes, closing == nil)
        }

        let (nodes, valid) = parse()
        guard valid else { return false }

        func hasOnlyKnownFields(_ nodes: [CardGenerationNode]) -> Bool {
            nodes.allSatisfy { node in
                switch node {
                case .replacement(let name): knownFields.contains(name)
                case .conditional(let name, let children), .negated(let name, let children):
                    knownFields.contains(name) && hasOnlyKnownFields(children)
                }
            }
        }
        guard hasOnlyKnownFields(nodes) else { return false }

        func hasRenderedField(_ nodes: [CardGenerationNode]) -> Bool {
            for node in nodes {
                switch node {
                case .replacement(let name):
                    if name != "FrontSide" && nonemptyFields.contains(name) { return true }
                case .conditional(let name, let children):
                    if nonemptyFields.contains(name) && hasRenderedField(children) { return true }
                case .negated(let name, let children):
                    if !nonemptyFields.contains(name) && hasRenderedField(children) { return true }
                }
            }
            return false
        }
        return hasRenderedField(nodes)
    }

    func syncCardsForNotetype(mid: Int64) throws {
        guard let model = notetype(id: mid) else { return }
        var noteIDs: [Int64] = []
        try db.query("SELECT id FROM notes WHERE mid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, mid)
        }) { stmt in
            noteIDs.append(sqlite3_column_int64(stmt, 0))
        }
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            try regenerateCards(forNoteID: nid, model: model, fields: note.fields, tags: note.tagList)
        }
        try touchCol()
        try refreshCounts()
    }

    /// Bury all active cards of the same note (Anki “Bury note”).
    func buryNote(nid: Int64, excludingCardID: Int64? = nil) throws {
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE nid = ? AND queue >= 0", bind: {
            SQLiteDatabase.bindInt64($0, 1, nid)
        }) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if id != excludingCardID { ids.append(id) }
        }
        try setCardsQueue(ids, queue: -3)
    }

    func buryCard(_ id: Int64) throws {
        try setCardsQueue([id], queue: -3)
    }

    func suspendNote(nid: Int64) throws {
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE nid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, nid)
        }) { stmt in
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        try setCardsQueue(ids, queue: -1)
    }

    func toggleMark(note: AnkiNote) throws {
        var tags = note.tagList
        if tags.contains("marked") {
            tags.removeAll { $0 == "marked" }
        } else {
            tags.append("marked")
        }
        try updateNote(note, fields: note.fields, tags: tags.joined(separator: " "))
    }

    func setDueDate(cardIDs: [Int64], daysFromToday: Int) throws {
        try setDueDate(cardIDs: cardIDs, minDays: daysFromToday, maxDays: daysFromToday, updateInterval: false)
    }

    /// Anki Set Due Date: `7`, `0-2`, or `60-90!` (! = also rewrite interval for reviews).
    func setDueDate(cardIDs: [Int64], minDays: Int, maxDays: Int, updateInterval: Bool) throws {
        let lo = max(0, min(minDays, maxDays))
        let hi = max(0, max(minDays, maxDays))
        let today = schedDay()
        guard hi <= max(Int(Int32.max) - today, 0) else {
            throw SQLiteError.exec("A data due escolhida ultrapassa o limite da coleção.")
        }
        try db.exec("BEGIN IMMEDIATE")
        do {
            for id in cardIDs {
                guard var card = try fetchCard(id: id) else { continue }
                let days = lo == hi ? lo : Int.random(in: lo...hi)
                let previousInterval = card.ivl
                if card.type == 0 || card.queue == 0 {
                    card.type = 2
                    card.factor = card.factor == 0 ? 2500 : card.factor
                    card.ivl = max(days, 1)
                } else if updateInterval {
                    card.ivl = max(days, 1)
                }
                card.queue = 2
                card.due = today + days
                card.mod = Int64(Date().timeIntervalSince1970)
                card.usn = -1
                try updateCard(card)
                try insertRevlog(AnkiRevlog(
                    id: timestampID(),
                    cid: card.id,
                    usn: -1,
                    ease: 0,
                    ivl: card.ivl,
                    lastIvl: previousInterval,
                    factor: card.factor,
                    time: 0,
                    type: 4
                ))
            }
            try refreshCounts()
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// Parse Anki due strings: `5`, `0-2`, `30!`, `60-90!`.
    static func parseDueDateInput(_ raw: String) -> (min: Int, max: Int, updateInterval: Bool)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let bang = s.hasSuffix("!")
        if bang { s.removeLast() }
        if let range = s.range(of: "-") {
            guard let a = Int(s[..<range.lowerBound].trimmingCharacters(in: .whitespaces)),
                  let b = Int(s[range.upperBound...].trimmingCharacters(in: .whitespaces)),
                  a >= 0, b >= 0 else { return nil }
            return (a, b, bang)
        }
        guard let n = Int(s), n >= 0 else { return nil }
        return (n, n, bang)
    }

    func forgetCards(_ ids: [Int64]) throws {
        try resetCards(ids, restoreOriginalPosition: false, clearCounts: false)
    }

    /// Anki “Reset card”: back to new queue, optionally keep original due position / clear reps·lapses.
    func resetCards(
        _ ids: [Int64],
        restoreOriginalPosition: Bool = false,
        clearCounts: Bool = false
    ) throws {
        guard !ids.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try db.exec("BEGIN IMMEDIATE")
        do {
            for id in ids {
                guard var card = try fetchCard(id: id) else { continue }
                let previousPosition: Int?
                if card.type == AnkiCard.CardType.new.rawValue {
                    previousPosition = card.odid != 0 ? card.odue : card.due
                } else {
                    previousPosition = FSRSCardData.originalPosition(in: card.data)
                }
                let priorInterval = card.ivl
                let priorFactor = card.factor
                let needsResetMarker = card.type != AnkiCard.CardType.new.rawValue || card.queue != AnkiCard.Queue.new.rawValue || card.reps > 0
                card.type = AnkiCard.CardType.new.rawValue
                card.queue = AnkiCard.Queue.new.rawValue
                if card.odid != 0 {
                    card.did = card.odid
                    card.odid = 0
                }
                if restoreOriginalPosition, let previousPosition {
                    card.due = previousPosition
                } else {
                    card.due = try nextNewCardPosition(for: card.did, randomize: false)
                }
                card.ivl = 0
                card.factor = 0
                if clearCounts {
                    card.reps = 0
                    card.lapses = 0
                }
                card.left = 0
                card.odue = 0
                card.data = FSRSCardData.clearingOriginalPosition(in: FSRSCardData.clearingMemory(in: card.data))
                card.mod = now
                card.usn = -1
                if needsResetMarker {
                    try insertRevlog(AnkiRevlog(
                        id: timestampID(),
                        cid: card.id,
                        usn: -1,
                        ease: 0,
                        ivl: 0,
                        lastIvl: priorInterval,
                        factor: priorFactor,
                        time: 0,
                        type: 4
                    ))
                }
                try updateCard(card)
            }
            try refreshCounts()
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    func siblingCardIDs(of card: AnkiCard) throws -> [Int64] {
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE nid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, card.nid)
        }) { stmt in
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    func changeNoteType(noteIDs: [Int64], to mid: Int64) throws {
        guard let model = notetype(id: mid) else { return }
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            guard note.mid != mid, let oldModel = notetype(id: note.mid) else { continue }

            let fieldsByNewOrd = defaultFieldMap(from: oldModel, to: model)
            var fields = note.fields
            var remappedFields = Array(repeating: "", count: (model.flds.map(\.ord).max() ?? -1) + 1)
            for field in model.flds {
                guard remappedFields.indices.contains(field.ord),
                      let oldOrd = fieldsByNewOrd[field.ord],
                      fields.indices.contains(oldOrd) else { continue }
                remappedFields[field.ord] = fields[oldOrd]
            }
            fields = remappedFields
            let flds = fields.joined(separator: "\u{1f}")
            let firstField = fields.first ?? ""
            let sortFieldIndex = model.flds.first(where: { $0.ord == model.sortf })?.ord ?? 0
            let sfld = stripHTMLPreservingMediaFilenames(fields.indices.contains(sortFieldIndex) ? fields[sortFieldIndex] : "")
            let tags = AnkiTag.join(note.tagList)
            let now = Int64(Date().timeIntervalSince1970)
            try db.run("""
                UPDATE notes SET mid = ?, mod = ?, usn = -1, tags = ?, flds = ?, sfld = ?, csum = ? WHERE id = ?
            """) { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, mid)
                SQLiteDatabase.bindInt64(stmt, 2, now)
                try SQLiteDatabase.bindText(stmt, 3, tags)
                try SQLiteDatabase.bindText(stmt, 4, flds)
                try SQLiteDatabase.bindText(stmt, 5, sfld)
                SQLiteDatabase.bindInt64(stmt, 6, self.fieldChecksum(firstField))
                SQLiteDatabase.bindInt64(stmt, 7, nid)
            }

            if !oldModel.isCloze && !model.isCloze {
                let oldOrdByNewOrd = defaultTemplateMap(from: oldModel, to: model)
                let newOrdByOldOrd = Dictionary(uniqueKeysWithValues: oldOrdByNewOrd.map { ($0.value, $0.key) })
                var cards: [(id: Int64, ord: Int)] = []
                try db.query("SELECT id, ord FROM cards WHERE nid = ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, nid)
                }) { stmt in
                    cards.append((sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int(stmt, 1))))
                }
                let removedCardIDs = cards.compactMap { newOrdByOldOrd[$0.ord] == nil ? $0.id : nil }
                try recordGraves(ids: removedCardIDs, type: 0)
                for cardID in removedCardIDs {
                    try db.run("DELETE FROM cards WHERE id = ?", bind: { SQLiteDatabase.bindInt64($0, 1, cardID) })
                }
                for card in cards {
                    guard let newOrd = newOrdByOldOrd[card.ord], newOrd != card.ord else { continue }
                    try db.run("UPDATE cards SET ord = ?, mod = ?, usn = -1 WHERE id = ?") { stmt in
                        SQLiteDatabase.bindInt(stmt, 1, newOrd)
                        SQLiteDatabase.bindInt64(stmt, 2, now)
                        SQLiteDatabase.bindInt64(stmt, 3, card.id)
                    }
                }
            } else if oldModel.isCloze && !model.isCloze {
                let maxOrd = model.tmpls.map(\.ord).max() ?? -1
                var removedCardIDs: [Int64] = []
                try db.query("SELECT id FROM cards WHERE nid = ? AND ord > ?", bind: { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, nid)
                    SQLiteDatabase.bindInt(stmt, 2, maxOrd)
                }) { stmt in
                    removedCardIDs.append(sqlite3_column_int64(stmt, 0))
                }
                try recordGraves(ids: removedCardIDs, type: 0)
                for cardID in removedCardIDs {
                    try db.run("DELETE FROM cards WHERE id = ?", bind: { SQLiteDatabase.bindInt64($0, 1, cardID) })
                }
            }

            let ords: Set<Int>
            if model.isCloze {
                ords = Set(ClozeHelper.ords(in: fields))
            } else {
                ords = Set(activeTemplateOrds(model: model, fields: fields, tags: note.tagList))
            }
            try syncNoteCards(
                noteID: nid,
                wanted: ords
            )
        }
        try reloadMeta()
        try touchCol()
        try refreshCounts()
    }

    private func defaultFieldMap(from oldModel: AnkiNotetype, to newModel: AnkiNotetype) -> [Int: Int] {
        var oldOrdsByName = Dictionary(uniqueKeysWithValues: oldModel.flds.map { ($0.name, $0.ord) })
        var used = Set<Int>()
        var map: [Int: Int] = [:]
        for field in newModel.flds {
            if let oldOrd = oldOrdsByName.removeValue(forKey: field.name) {
                map[field.ord] = oldOrd
                used.insert(oldOrd)
            }
        }
        let remainingOldOrds = oldModel.flds.map(\.ord).filter { !used.contains($0) }.sorted()
        for field in newModel.flds where map[field.ord] == nil {
            guard let oldOrd = remainingOldOrds.first(where: { !used.contains($0) }) else { continue }
            map[field.ord] = oldOrd
            used.insert(oldOrd)
        }
        return map
    }

    private func defaultTemplateMap(from oldModel: AnkiNotetype, to newModel: AnkiNotetype) -> [Int: Int] {
        var oldOrdsByName = Dictionary(uniqueKeysWithValues: oldModel.tmpls.map { ($0.name, $0.ord) })
        var used = Set<Int>()
        var map: [Int: Int] = [:]
        for template in newModel.tmpls {
            if let oldOrd = oldOrdsByName.removeValue(forKey: template.name) {
                map[template.ord] = oldOrd
                used.insert(oldOrd)
            }
        }
        let remainingOldOrds = oldModel.tmpls.map(\.ord).filter { !used.contains($0) }.sorted()
        var remainingIndex = 0
        for template in newModel.tmpls where map[template.ord] == nil {
            if remainingIndex < remainingOldOrds.count {
                map[template.ord] = remainingOldOrds[remainingIndex]
                used.insert(remainingOldOrds[remainingIndex])
                remainingIndex += 1
            }
        }
        return map
    }

    func replaceTag(in noteIDs: [Int64], from old: String, to new: String) throws {
        let prefixes = AnkiTag.split(old)
        guard !prefixes.isEmpty else { return }
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            let tags = note.tagList.map { tag in
                prefixes.lazy.compactMap { AnkiTag.replacingPrefix(tag, from: $0, to: new) }.first ?? tag
            }
            let updated = AnkiTag.canonicalized(tags.filter { !$0.isEmpty }.joined(separator: " "), existing: Array(self.tags.keys))
            let current = AnkiTag.canonicalized(note.tags, existing: Array(self.tags.keys))
            guard updated != current else { continue }
            try updateNote(note, fields: note.fields, tags: updated.joined(separator: " "))
        }
    }

    func addTag(to noteIDs: [Int64], tag: String) throws {
        let additions = AnkiTag.split(tag)
        guard !additions.isEmpty else { return }
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            var tags = note.tagList
            let existing = Set(tags.map(AnkiTag.key))
            for addition in additions where !existing.contains(AnkiTag.key(addition)) { tags.append(addition) }
            let updated = AnkiTag.canonicalized(tags.joined(separator: " "), existing: Array(self.tags.keys))
            let current = AnkiTag.canonicalized(note.tags, existing: Array(self.tags.keys))
            guard updated != current else { continue }
            try updateNote(note, fields: note.fields, tags: updated.joined(separator: " "))
        }
    }

    func removeTag(from noteIDs: [Int64], tag: String) throws {
        let removals = AnkiTag.split(tag)
        guard !removals.isEmpty else { return }
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            let tags = note.tagList.filter { current in
                !removals.contains { AnkiTag.replacingPrefix(current, from: $0, to: "") != nil }
            }
            let updated = AnkiTag.canonicalized(tags.joined(separator: " "), existing: Array(self.tags.keys))
            let current = AnkiTag.canonicalized(note.tags, existing: Array(self.tags.keys))
            guard updated != current else { continue }
            try updateNote(note, fields: note.fields, tags: updated.joined(separator: " "))
        }
    }

    func emptyCards() throws -> Int {
        let before = try db.scalarInt("SELECT COUNT(*) FROM cards")
        var orphanedCardIDs: [Int64] = []
        try db.query("SELECT id FROM cards WHERE nid NOT IN (SELECT id FROM notes)") { stmt in
            orphanedCardIDs.append(sqlite3_column_int64(stmt, 0))
        }
        try recordGraves(ids: orphanedCardIDs, type: 0)
        try db.run("DELETE FROM cards WHERE nid NOT IN (SELECT id FROM notes)")
        var affectedNoteIDs = Set<Int64>()

        struct NoteRow {
            let id: Int64
            let mid: Int64
            let fields: [String]
            let tags: [String]
        }
        var noteRows: [NoteRow] = []
        try db.query("SELECT id, mid, flds, tags FROM notes") { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let mid = sqlite3_column_int64(stmt, 1)
            let flds = SQLiteDatabase.text(stmt, 2)
            let tags = AnkiTag.split(SQLiteDatabase.text(stmt, 3))
            let parts = flds.components(separatedBy: "\u{1f}")
            noteRows.append(NoteRow(id: id, mid: mid, fields: parts, tags: tags))
        }

        for row in noteRows {
            guard let model = notetype(id: row.mid) else {
                try recordCardGraves(noteID: row.id)
                try db.run("DELETE FROM cards WHERE nid = ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, row.id)
                })
                affectedNoteIDs.insert(row.id)
                continue
            }
            let wanted: Set<Int>
            if model.isCloze {
                wanted = Set(ClozeHelper.ords(in: row.fields))
            } else {
                wanted = Set(activeTemplateOrds(model: model, fields: row.fields, tags: row.tags))
            }
            if wanted.isEmpty {
                try recordCardGraves(noteID: row.id)
                try db.run("DELETE FROM cards WHERE nid = ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, row.id)
                })
                affectedNoteIDs.insert(row.id)
            } else {
                let ords = wanted.sorted()
                let placeholders = ords.map { _ in "?" }.joined(separator: ",")
                var removedCardIDs: [Int64] = []
                try db.query("SELECT id FROM cards WHERE nid = ? AND ord NOT IN (\(placeholders))", bind: { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, row.id)
                    for (i, ord) in ords.enumerated() {
                        SQLiteDatabase.bindInt(stmt, Int32(i + 2), ord)
                    }
                }) { stmt in
                    removedCardIDs.append(sqlite3_column_int64(stmt, 0))
                }
                try recordGraves(ids: removedCardIDs, type: 0)
                if !removedCardIDs.isEmpty { affectedNoteIDs.insert(row.id) }
                try db.run(
                    "DELETE FROM cards WHERE nid = ? AND ord NOT IN (\(placeholders))",
                    bind: { stmt in
                        SQLiteDatabase.bindInt64(stmt, 1, row.id)
                        for (i, ord) in ords.enumerated() {
                            SQLiteDatabase.bindInt(stmt, Int32(i + 2), ord)
                        }
                    }
                )
            }
        }

        var emptyNoteIDs: [Int64] = []
        for noteID in affectedNoteIDs {
            if try db.scalarInt("SELECT COUNT(*) FROM cards WHERE nid = ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, noteID)
            }) == 0 {
                emptyNoteIDs.append(noteID)
            }
        }
        if !emptyNoteIDs.isEmpty { try deleteNotes(ids: emptyNoteIDs) }

        let after = try db.scalarInt("SELECT COUNT(*) FROM cards")
        try refreshCounts()
        return before - after
    }

    private func recordCardGraves(noteID: Int64) throws {
        var cardIDs: [Int64] = []
        try db.query("SELECT id FROM cards WHERE nid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) { stmt in
            cardIDs.append(sqlite3_column_int64(stmt, 0))
        }
        try recordGraves(ids: cardIDs, type: 0)
    }

    func cardInfoText(_ card: AnkiCard, note: AnkiNote) -> String {
        let deckName = deck(id: card.did)?.name ?? "?"
        let nt = notetype(id: note.mid)?.name ?? "?"
        let typeName: String = {
            switch card.type {
            case 0: return "Novo"
            case 1: return "Aprendizagem"
            case 2: return "Revisão"
            case 3: return "Reaprendizagem"
            default: return "\(card.type)"
            }
        }()
        let queueName: String = {
            switch card.queue {
            case 0: return "Novo"
            case 1: return "Aprendizagem"
            case 2: return "Revisão"
            case 3: return "Aprend. dia"
            case -1: return "Suspenso"
            case -2: return "Oculto (irmão)"
            case -3: return "Oculto"
            default: return "\(card.queue)"
            }
        }()
        return """
        ID cartão: \(card.id)
        ID nota: \(note.id)
        Baralho: \(deckName)
        Tipo de nota: \(nt)
        Tipo: \(typeName)
        Fila: \(queueName)
        Due: \(card.due)
        Intervalo: \(card.ivl)d
        Facilidade: \(card.factor)
        Reps: \(card.reps)
        Lapses: \(card.lapses)
        Bandeira: \(card.flags)
        Tags: \(note.tagList.joined(separator: " "))
        """
    }

    func setDeckCollapsed(_ deck: AnkiDeck, collapsed: Bool) throws {
        var next = decks
        guard let idx = next.firstIndex(where: { $0.id == deck.id }) else { return }
        next[idx].collapsed = collapsed
        try saveDecks(next)
    }

    @discardableResult
    func duplicateNotes(_ noteIDs: [Int64]) throws -> [Int64] {
        var duplicates: [Int64] = []
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            var did: Int64 = 1
            try db.query("SELECT did FROM cards WHERE nid = ? LIMIT 1", bind: {
                SQLiteDatabase.bindInt64($0, 1, nid)
            }) { stmt in
                did = sqlite3_column_int64(stmt, 0)
            }
            try addNote(mid: note.mid, did: did, fields: note.fields, tags: note.tagList.joined(separator: " "))
            duplicates.append(try db.scalarInt64("SELECT MAX(id) FROM notes"))
        }
        try refreshCounts()
        return duplicates
    }

    func cardIDs(ofNotes noteIDs: [Int64]) throws -> [Int64] {
        guard !noteIDs.isEmpty else { return [] }
        var ids: [Int64] = []
        for start in stride(from: 0, to: noteIDs.count, by: 500) {
            let batch = Array(noteIDs[start..<min(start + 500, noteIDs.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT id FROM cards WHERE nid IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id)
                }
            }) { stmt in
                ids.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return ids
    }

    func noteIDs(ofCards cardIDs: [Int64]) throws -> [Int64] {
        guard !cardIDs.isEmpty else { return [] }
        var noteIDs = Set<Int64>()
        for start in stride(from: 0, to: cardIDs.count, by: 500) {
            let batch = Array(cardIDs[start..<min(start + 500, cardIDs.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT DISTINCT nid FROM cards WHERE id IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id)
                }
            }) { stmt in
                noteIDs.insert(sqlite3_column_int64(stmt, 0))
            }
        }
        return Array(noteIDs)
    }

    /// Reposition new cards (Anki: start, step, randomize, shift positions at or after the start).
    func repositionNewCards(_ ids: [Int64], startingFrom: Int = 0, step: Int = 1, random: Bool = false, shift: Bool = false) throws {
        var selected: [AnkiCard] = []
        for id in ids {
            if let card = try fetchCard(id: id) { selected.append(card) }
        }
        let step = max(step, 1)
        if shift, !ids.isEmpty {
            let bump = ids.count * step
            let now = Int64(Date().timeIntervalSince1970)
            try db.run("UPDATE cards SET due = due + \(bump), mod = \(now), usn = -1 WHERE type = 0 AND due >= \(startingFrom)")
        }

        var noteIDs = Array(Set(selected.map(\.nid))).sorted()
        if random { noteIDs.shuffle() }
        let positions = Dictionary(uniqueKeysWithValues: noteIDs.enumerated().map { index, nid in
            (nid, startingFrom + index * step)
        })
        for selectedCard in selected {
            guard selectedCard.type == AnkiCard.CardType.new.rawValue || selectedCard.queue == AnkiCard.Queue.new.rawValue,
                  var card = try fetchCard(id: selectedCard.id),
                  let position = positions[card.nid] else { continue }
            if card.odid != 0 {
                card.odue = position
            } else {
                card.due = position
            }
            card.mod = Int64(Date().timeIntervalSince1970)
            card.usn = -1
            try updateCard(card)
        }
        try refreshCounts()
    }
}
