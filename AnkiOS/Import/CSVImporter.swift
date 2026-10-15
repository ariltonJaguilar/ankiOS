import Foundation
import UniformTypeIdentifiers

/// Import notes from CSV / TSV / tab-or-comma text (Anki-style field columns).
@MainActor
struct CSVImporter {
    let store: CollectionStore

    /// First line may be headers matching field names; otherwise columns map by order.
    @discardableResult
    func importFile(
        at url: URL,
        deckID: Int64? = nil,
        notetypeID: Int64? = nil,
        delimiter: Character? = nil
    ) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try importText(text, deckID: deckID, notetypeID: notetypeID, delimiter: delimiter)
    }

    @discardableResult
    func importText(
        _ text: String,
        deckID: Int64? = nil,
        notetypeID: Int64? = nil,
        delimiter: Character? = nil
    ) throws -> Int {
        let mid = notetypeID ?? store.notetypes.first?.id
        guard let mid, let nt = store.notetype(id: mid) else {
            throw CSVImportError.noNotetype
        }
        let did = deckID
            ?? store.decks.first(where: { $0.name != "Default" })?.id
            ?? store.decks.first?.id
            ?? 1

        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            }
        guard !lines.isEmpty else { return 0 }

        let sep = delimiter ?? detectDelimiter(lines[0])
        var start = 0
        var columnMap: [Int]? = nil
        let first = parseRow(lines[0], separator: sep)
        if looksLikeHeader(first, notetype: nt) {
            columnMap = first.map { header in
                nt.flds.firstIndex { $0.name.caseInsensitiveCompare(header) == .orderedSame } ?? -1
            }
            start = 1
        }

        var imported = 0
        for i in start..<lines.count {
            let cols = parseRow(lines[i], separator: sep)
            guard cols.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            var fields = Array(repeating: "", count: nt.flds.count)
            if let map = columnMap {
                for (ci, fi) in map.enumerated() where fi >= 0 && ci < cols.count {
                    fields[fi] = cols[ci]
                }
            } else {
                for (ci, value) in cols.enumerated() where ci < fields.count {
                    fields[ci] = value
                }
            }
            var tags = ""
            if cols.count > nt.flds.count {
                tags = cols[nt.flds.count]
                    .replacingOccurrences(of: ",", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            try store.addNote(mid: mid, did: did, fields: fields, tags: tags)
            imported += 1
        }
        store.notifyDeckContentAdded()
        return imported
    }

    private func detectDelimiter(_ line: String) -> Character {
        let tabs = line.filter { $0 == "\t" }.count
        let commas = line.filter { $0 == "," }.count
        let semis = line.filter { $0 == ";" }.count
        if tabs >= commas && tabs >= semis && tabs > 0 { return "\t" }
        if semis > commas { return ";" }
        return ","
    }

    private func looksLikeHeader(_ cols: [String], notetype: AnkiNotetype) -> Bool {
        let names = Set(notetype.flds.map { $0.name.lowercased() })
        let hits = cols.filter { names.contains($0.lowercased()) }.count
        return hits >= 1 && hits >= cols.count / 2
    }

    private func parseRow(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if inQuotes && next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
                i = line.index(after: i)
                continue
            }
            if ch == separator && !inQuotes {
                fields.append(current)
                current = ""
                i = line.index(after: i)
                continue
            }
            current.append(ch)
            i = line.index(after: i)
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

enum CSVImportError: LocalizedError {
    case noNotetype
    var errorDescription: String? {
        switch self {
        case .noNotetype: "Nenhum tipo de nota disponível para importar."
        }
    }
}
