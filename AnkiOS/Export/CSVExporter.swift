import Foundation

@MainActor
struct CSVExporter {
    let store: CollectionStore

    func exportNotes(noteIDs: [Int64]? = nil, to url: URL, separator: Character = "\t") throws {
        var notes: [AnkiNote] = []
        if let noteIDs, !noteIDs.isEmpty {
            for nid in noteIDs {
                if let n = try store.fetchNote(id: nid) { notes.append(n) }
            }
        } else {
            try store.db.query("SELECT * FROM notes ORDER BY id") { stmt in
                notes.append(CollectionStore.mapNote(stmt))
            }
        }

        let fieldCount = notes.compactMap { store.notetype(id: $0.mid)?.flds.count }.max() ?? 0
        let tagsColumn = fieldCount + 4
        var lines = [
            "#separator:\(separatorName(separator))",
            "#html:true",
            "#guid column:1",
            "#notetype column:2",
            "#deck column:3",
            "#tags column:\(tagsColumn)"
        ]

        for note in notes {
            guard let model = store.notetype(id: note.mid) else { continue }
            var fields = note.fields.prefix(fieldCount).map(stripRedundantSections)
            while fields.count < fieldCount { fields.append("") }
            let did = try store.db.scalarInt64("SELECT CASE WHEN odid != 0 THEN odid ELSE did END FROM cards WHERE nid = ? ORDER BY ord LIMIT 1", bind: {
                SQLiteDatabase.bindInt64($0, 1, note.id)
            })
            let deckName = store.deck(id: did)?.name ?? "Default"
            let cols = [note.guid, model.name, deckName] + fields + [note.tagList.joined(separator: " ")]
            lines.append(cols.map { csvEscape($0, separator: separator) }.joined(separator: String(separator)))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func separatorName(_ separator: Character) -> String {
        switch separator {
        case "\t": "tab"
        case ",": "comma"
        case ";": "semicolon"
        case " ": "space"
        case "|": "pipe"
        default: String(separator)
        }
    }

    private func csvEscape(_ value: String, separator: Character) -> String {
        if value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r") || value.contains("#") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func stripRedundantSections(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<style>.*?</style>|\[\[type:[^\]]+\]\]"#) else {
            return value
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: ""
        )
    }
}
