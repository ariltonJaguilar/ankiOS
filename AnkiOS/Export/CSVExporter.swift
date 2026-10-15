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
            try store.db.query("SELECT * FROM notes ORDER BY sfld COLLATE NOCASE") { stmt in
                notes.append(CollectionStore.mapNote(stmt))
            }
        }

        guard let first = notes.first, let nt = store.notetype(id: first.mid) else {
            try "".write(to: url, atomically: true, encoding: .utf8)
            return
        }

        var lines: [String] = []
        let headers = nt.flds.map(\.name) + ["tags"]
        lines.append(headers.map { csvEscape($0, separator: separator) }.joined(separator: String(separator)))

        for note in notes {
            guard let model = store.notetype(id: note.mid) else { continue }
            var cols = note.fields
            while cols.count < model.flds.count { cols.append("") }
            cols = Array(cols.prefix(model.flds.count))
            cols.append(note.tagList.joined(separator: " "))
            lines.append(cols.map { csvEscape($0, separator: separator) }.joined(separator: String(separator)))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func csvEscape(_ value: String, separator: Character) -> String {
        if value.contains(separator) || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
