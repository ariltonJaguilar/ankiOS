import Foundation
import SQLite3

extension CollectionStore {
    /// Regenerate cards for one note after its notetype or cloze field content changed.
    func regenerateCards(forNoteID noteID: Int64) throws {
        guard let note = try fetchNote(id: noteID),
              let model = notetype(id: note.mid) else { return }
        try regenerateCards(forNoteID: noteID, model: model, fields: note.fields)
    }

    private func regenerateCards(forNoteID noteID: Int64, model: AnkiNotetype, fields: [String]) throws {
        if model.isCloze {
            var wanted = Set(ClozeHelper.ords(in: fields))
            if wanted.isEmpty { wanted = [0] }
            try syncNoteCards(
                noteID: noteID,
                mid: model.id,
                wanted: wanted,
                unsuspendRestoredEmpty: true,
                isCloze: true
            )
        } else {
            let wanted = Set(activeTemplateOrds(model: model, fields: fields))
            try syncNoteCards(
                noteID: noteID,
                mid: model.id,
                wanted: wanted.isEmpty ? [0] : wanted,
                unsuspendRestoredEmpty: false,
                isCloze: false
            )
        }
    }

    /// Anki card generation: skip templates whose question side renders empty
    /// (e.g. Basic optional reverse when “Add Reverse” is blank).
    func activeTemplateOrds(model: AnkiNotetype, fields: [String]) -> [Int] {
        var map: [String: String] = [:]
        for field in model.flds {
            map[field.name] = field.ord < fields.count ? fields[field.ord] : ""
        }
        return model.tmpls.compactMap { tmpl in
            let rendered = TemplateEngine.render(
                template: tmpl.qfmt,
                fields: map,
                frontSide: nil,
                clozeOrd: nil,
                questionSide: true
            )
            let stripped = rendered
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : tmpl.ord
        }
    }

    /// After a notetype’s templates change, add/remove cards for every note of that type.
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
            try regenerateCards(forNoteID: nid, model: model, fields: note.fields)
        }
        try touchCol()
        try refreshCounts()
    }

    /// Bury all sibling cards of the same note (Anki “Bury note”).
    func buryNote(nid: Int64, excludingCardID: Int64? = nil) throws {
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE nid = ? AND queue >= 0", bind: {
            SQLiteDatabase.bindInt64($0, 1, nid)
        }) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if id != excludingCardID { ids.append(id) }
        }
        try setCardsQueue(ids, queue: -2)
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
        for id in cardIDs {
            guard var card = try fetchCard(id: id) else { continue }
            let days = lo == hi ? lo : Int.random(in: lo...hi)
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
            try updateCard(card)
        }
        try refreshCounts()
    }

    /// Parse Anki due strings: `5`, `0-2`, `30!`, `60-90!`.
    static func parseDueDateInput(_ raw: String) -> (min: Int, max: Int, updateInterval: Bool)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let bang = s.hasSuffix("!")
        if bang { s.removeLast() }
        if let range = s.range(of: "-") {
            guard let a = Int(s[..<range.lowerBound].trimmingCharacters(in: .whitespaces)),
                  let b = Int(s[range.upperBound...].trimmingCharacters(in: .whitespaces)) else { return nil }
            return (a, b, bang)
        }
        guard let n = Int(s) else { return nil }
        return (n, n, bang)
    }

    func forgetCards(_ ids: [Int64]) throws {
        try resetCards(ids, restoreOriginalPosition: false, clearCounts: true)
    }

    /// Anki “Reset card”: back to new queue, optionally keep original due position / clear reps·lapses.
    func resetCards(
        _ ids: [Int64],
        restoreOriginalPosition: Bool = false,
        clearCounts: Bool = true
    ) throws {
        guard !ids.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        for id in ids {
            guard var card = try fetchCard(id: id) else { continue }
            let originalDue = card.due
            card.type = 0
            card.queue = 0
            if restoreOriginalPosition, originalDue > 0 {
                card.due = originalDue
            } else {
                // End of new queue (Anki default forget).
                let maxDue = (try? db.scalarInt("SELECT COALESCE(MAX(due), 0) FROM cards WHERE queue = 0")) ?? 0
                card.due = maxDue + 1
            }
            card.ivl = 0
            card.factor = 0
            if clearCounts {
                card.reps = 0
                card.lapses = 0
            }
            card.left = 0
            card.odue = 0
            card.data = ""
            card.mod = now
            try updateCard(card)
        }
        try refreshCounts()
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
            var fields = note.fields
            while fields.count < model.flds.count { fields.append("") }
            if fields.count > model.flds.count {
                fields = Array(fields.prefix(model.flds.count))
            }
            var originalDid: Int64 = 1
            try db.query("SELECT did FROM cards WHERE nid = ? LIMIT 1", bind: {
                SQLiteDatabase.bindInt64($0, 1, nid)
            }) { stmt in
                originalDid = sqlite3_column_int64(stmt, 0)
            }
            try updateNote(note, fields: fields, tags: note.tagList.joined(separator: " "))
            // Fix mid after updateNote (updateNote doesn't change mid)
            try db.run("UPDATE notes SET mid = ? WHERE id = ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, mid)
                SQLiteDatabase.bindInt64($0, 2, nid)
            })
            try db.run("DELETE FROM cards WHERE nid = ?", bind: { SQLiteDatabase.bindInt64($0, 1, nid) })
            let ords: [Int]
            if model.isCloze {
                ords = ClozeHelper.ords(in: fields)
            } else {
                let active = activeTemplateOrds(model: model, fields: fields)
                ords = active.isEmpty ? [0] : active
            }
            let now = Int64(Date().timeIntervalSince1970)
            for ord in ords {
                let cid = timestampID()
                try db.run("""
                    INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                    VALUES (?, ?, ?, ?, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
                """) { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, cid)
                    SQLiteDatabase.bindInt64(stmt, 2, nid)
                    SQLiteDatabase.bindInt64(stmt, 3, originalDid)
                    SQLiteDatabase.bindInt(stmt, 4, ord)
                    SQLiteDatabase.bindInt64(stmt, 5, now)
                    SQLiteDatabase.bindInt(stmt, 6, Int(nid % 1_000_000))
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        try reloadMeta()
        try refreshCounts()
    }

    func replaceTag(in noteIDs: [Int64], from old: String, to new: String) throws {
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            var tags = note.tagList.map { $0 == old ? new : $0 }
            try updateNote(note, fields: note.fields, tags: tags.filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    func addTag(to noteIDs: [Int64], tag: String) throws {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            var tags = note.tagList
            if !tags.contains(t) { tags.append(t) }
            try updateNote(note, fields: note.fields, tags: tags.joined(separator: " "))
        }
    }

    func removeTag(from noteIDs: [Int64], tag: String) throws {
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            let tags = note.tagList.filter { $0 != tag }
            try updateNote(note, fields: note.fields, tags: tags.joined(separator: " "))
        }
    }

    func emptyCards() throws -> Int {
        let before = try db.scalarInt("SELECT COUNT(*) FROM cards")
        try db.run("DELETE FROM cards WHERE nid NOT IN (SELECT id FROM notes)")

        struct NoteRow {
            let id: Int64
            let mid: Int64
            let fields: [String]
        }
        var noteRows: [NoteRow] = []
        try db.query("SELECT id, mid, flds FROM notes") { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let mid = sqlite3_column_int64(stmt, 1)
            let flds = SQLiteDatabase.text(stmt, 2)
            let parts = flds.components(separatedBy: "\u{1f}")
            noteRows.append(NoteRow(id: id, mid: mid, fields: parts))
        }

        for row in noteRows {
            guard let model = notetype(id: row.mid) else {
                try db.run("DELETE FROM cards WHERE nid = ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, row.id)
                })
                continue
            }
            let wanted: Set<Int>
            if model.isCloze {
                wanted = Set(ClozeHelper.ords(in: row.fields))
            } else {
                wanted = Set(activeTemplateOrds(model: model, fields: row.fields))
            }
            if wanted.isEmpty {
                try db.run("DELETE FROM cards WHERE nid = ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, row.id)
                })
            } else {
                let ords = wanted.sorted()
                let placeholders = ords.map { _ in "?" }.joined(separator: ",")
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
        for row in noteRows {
            if row.fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                emptyNoteIDs.append(row.id)
            }
        }
        if !emptyNoteIDs.isEmpty { try deleteNotes(ids: emptyNoteIDs) }

        let after = try db.scalarInt("SELECT COUNT(*) FROM cards")
        try refreshCounts()
        return before - after
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

    func duplicateNotes(_ noteIDs: [Int64]) throws {
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            var did: Int64 = 1
            try db.query("SELECT did FROM cards WHERE nid = ? LIMIT 1", bind: {
                SQLiteDatabase.bindInt64($0, 1, nid)
            }) { stmt in
                did = sqlite3_column_int64(stmt, 0)
            }
            try addNote(mid: note.mid, did: did, fields: note.fields, tags: note.tagList.joined(separator: " "))
        }
        try refreshCounts()
    }

    func cardIDs(ofNotes noteIDs: [Int64]) throws -> [Int64] {
        guard !noteIDs.isEmpty else { return [] }
        let placeholders = noteIDs.map { _ in "?" }.joined(separator: ",")
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE nid IN (\(placeholders))", bind: { stmt in
            for (i, id) in noteIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        }) { stmt in
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    /// Reposition new cards (Anki: start, step, randomize, shift positions at or after the start).
    func repositionNewCards(_ ids: [Int64], startingFrom: Int = 0, step: Int = 1, random: Bool = false, shift: Bool = false) throws {
        var newIDs: [Int64] = []
        for id in ids {
            if let card = try fetchCard(id: id), card.queue == 0 { newIDs.append(id) }
        }
        if random { newIDs.shuffle() }
        let step = max(step, 1)
        if shift, !newIDs.isEmpty {
            let bump = newIDs.count * step
            let keep = newIDs.map(String.init).joined(separator: ",")
            let now = Int64(Date().timeIntervalSince1970)
            try db.run("UPDATE cards SET due = due + \(bump), mod = \(now) WHERE queue = 0 AND due >= \(startingFrom) AND id NOT IN (\(keep))")
        }
        var due = startingFrom
        for id in newIDs {
            guard var card = try fetchCard(id: id), card.queue == 0 else { continue }
            card.due = due
            card.mod = Int64(Date().timeIntervalSince1970)
            try updateCard(card)
            due += step
        }
        try refreshCounts()
    }
}
