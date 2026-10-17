import Foundation
import SQLite3
import UniformTypeIdentifiers

/// Import notes from CSV / TSV / tab-or-comma text (Anki-style field columns).
@MainActor
struct CSVImporter {
    let store: CollectionStore

    enum ColumnMapping: Hashable, Identifiable {
        case field(Int)
        case tags
        case deck
        case notetype
        case guid
        case ignore

        var id: Self { self }

        var title: String {
            switch self {
            case .field(let index): "Campo \(index + 1)"
            case .tags: "Etiquetas"
            case .deck: "Baralho"
            case .notetype: "Tipo de nota"
            case .guid: "GUID"
            case .ignore: "Ignorar"
            }
        }
    }

    struct Preview {
        let delimiter: Character
        let columnNames: [String]
        let rows: [[String]]
        let suggestsHeader: Bool
        let usesColumnLabels: Bool
        let specialColumns: [Int: String]
        let existingNotePolicy: ExistingNotePolicy?
        let matchWithinDeck: Bool?
        let directiveDeck: String?
        let directiveDeckID: Int64?
        let directiveNotetypeID: Int64?
    }

    enum ExistingNotePolicy: String, CaseIterable, Hashable, Identifiable {
        case update
        case ignore
        case importAsNew

        var id: String { rawValue }

        var title: String {
            switch self {
            case .update: "Atualizar nota existente"
            case .ignore: "Ignorar duplicatas"
            case .importAsNew: "Importar como novas notas"
            }
        }
    }

    struct ImportResult {
        var added = 0
        var updated = 0
        var ignored = 0

        var summary: String {
            "CSV: \(added) nova(s), \(updated) atualizada(s), \(ignored) ignorada(s)."
        }
    }

    func preview(_ text: String, delimiter: Character? = nil, notetypeID: Int64? = nil, skipFirstRow: Bool? = nil) -> Preview {
        let normalizedText = text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let sourceRows = normalizedText.components(separatedBy: "\n")
        let directives = sourceRows
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let specialColumns = Self.specialColumnMap(directives)
        let directiveDeck = directives.first(where: { $0.lowercased().hasPrefix("#deck:") })
            .map { String($0.dropFirst("#deck:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let directiveNotetype = directives.first(where: { $0.lowercased().hasPrefix("#notetype:") })
            .map { String($0.dropFirst("#notetype:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let directiveDeckID = directiveDeck.flatMap { resolveDeck($0)?.id }
        let directiveNotetypeID = directiveNotetype.flatMap { resolveNotetype($0)?.id }
        let hasLegacyTagsLine = sourceRows.first?.lowercased().hasPrefix("tags:") == true
        let sourceForRows = hasLegacyTagsLine ? Array(sourceRows.dropFirst()) : sourceRows
        let firstDataLine = sourceForRows.first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        } ?? ""
        let directiveSeparator = directives.first(where: { $0.lowercased().hasPrefix("#separator:") })
            .map { String($0.dropFirst("#separator:".count)).trimmingCharacters(in: .whitespaces).lowercased() }
        let separator = delimiter ?? separator(from: directiveSeparator) ?? detectDelimiter(firstDataLine)
        let defaultNotetype = notetypeID.flatMap { store.notetype(id: $0) }
            ?? directiveNotetypeID.flatMap { store.notetype(id: $0) }
            ?? store.notetypes.first
        let rows = parseRows(sourceForRows.joined(separator: "\n"), separator: separator).filter { row in
            !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).hasPrefix("#"))
                && row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        let declaredColumns = directives.first(where: { $0.lowercased().hasPrefix("#columns:") })
            .map { String($0.dropFirst("#columns:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { parseColumnNames($0, separator: separator) }
        let duplicatePolicy = directives.first(where: { $0.lowercased().hasPrefix("#if matches:") })
            .map { String($0.dropFirst("#if matches:".count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { value -> ExistingNotePolicy? in
                switch value {
                case "update current": .update
                case "keep current": .ignore
                case "keep both": .importAsNew
                default: nil
                }
            }
        let matchWithinDeck = directives.first(where: { $0.lowercased().hasPrefix("#match scope:") })
            .map { String($0.dropFirst("#match scope:".count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { value -> Bool? in
                switch value {
                case "notetype": false
                case "notetype + deck": true
                default: nil
                }
            }
        let suggestsHeader = declaredColumns == nil
            && rows.first.map { row in defaultNotetype.map { looksLikeHeader(row, notetype: $0) } ?? false } == true
        let labels = declaredColumns ?? (suggestsHeader ? rows.first : nil)
        let columnCount = max(labels?.count ?? 0, rows.map(\.count).max() ?? 0)
        let columnNames = (0..<columnCount).map { index in
            labels.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? "Coluna \(index + 1)"
        }
        let visibleRows = (skipFirstRow ?? suggestsHeader) ? Array(rows.dropFirst()) : rows
        return Preview(
            delimiter: separator,
            columnNames: columnNames,
            rows: Array(visibleRows.prefix(5)),
            suggestsHeader: suggestsHeader,
            usesColumnLabels: declaredColumns != nil || suggestsHeader,
            specialColumns: specialColumns,
            existingNotePolicy: duplicatePolicy,
            matchWithinDeck: matchWithinDeck,
            directiveDeck: directiveDeck,
            directiveDeckID: directiveDeckID,
            directiveNotetypeID: directiveNotetypeID
        )
    }

    func suggestedMappings(for preview: Preview, notetype: AnkiNotetype) -> [ColumnMapping] {
        var fieldPosition = 0
        return preview.columnNames.enumerated().map { index, name in
            if let special = preview.specialColumns[index] {
                switch special {
                case "tags": return .tags
                case "deck": return .deck
                case "notetype": return .notetype
                case "guid": return .guid
                default: break
                }
            }
            let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["tags", "deck", "notetype", "guid"].contains(lower) {
                switch lower {
                case "tags": return .tags
                case "deck": return .deck
                case "notetype": return .notetype
                default: return .guid
                }
            }

            let fallbackIndex = fieldPosition
            fieldPosition += 1
            if preview.usesColumnLabels,
               let field = notetype.flds.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return .field(field)
            } else if fallbackIndex < notetype.flds.count {
                return .field(fallbackIndex)
            } else {
                return .ignore
            }
        }
    }

    /// First line may be headers matching field names; otherwise columns map by order.
    @discardableResult
    func importFile(
        at url: URL,
        deckID: Int64? = nil,
        notetypeID: Int64? = nil,
        delimiter: Character? = nil,
        allowHTML: Bool? = nil,
        existingNotePolicy: ExistingNotePolicy? = nil,
        matchWithinDeck: Bool? = nil,
        tagsForAllNotes: String = "",
        tagsForUpdatedNotes: String = "",
        columnMappings: [ColumnMapping]? = nil,
        skipFirstRow: Bool? = nil
    ) throws -> ImportResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try importText(
            text,
            deckID: deckID,
            notetypeID: notetypeID,
            delimiter: delimiter,
            allowHTML: allowHTML,
            existingNotePolicy: existingNotePolicy,
            matchWithinDeck: matchWithinDeck,
            tagsForAllNotes: tagsForAllNotes,
            tagsForUpdatedNotes: tagsForUpdatedNotes,
            columnMappings: columnMappings,
            skipFirstRow: skipFirstRow
        )
    }

    @discardableResult
    func importText(
        _ text: String,
        deckID: Int64? = nil,
        notetypeID: Int64? = nil,
        delimiter: Character? = nil,
        allowHTML: Bool? = nil,
        existingNotePolicy: ExistingNotePolicy? = nil,
        matchWithinDeck: Bool? = nil,
        tagsForAllNotes: String = "",
        tagsForUpdatedNotes: String = "",
        columnMappings: [ColumnMapping]? = nil,
        skipFirstRow: Bool? = nil
    ) throws -> ImportResult {
        let normalizedText = text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let sourceRows = normalizedText.components(separatedBy: "\n")
        let hasLegacyTagsLine = sourceRows.first?.lowercased().hasPrefix("tags:") == true
        let sourceForRows = hasLegacyTagsLine ? Array(sourceRows.dropFirst()) : sourceRows
        let directives = sourceRows
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let fileOptions = preview(text, delimiter: delimiter, notetypeID: notetypeID, skipFirstRow: skipFirstRow)
        let effectiveExistingNotePolicy = existingNotePolicy ?? fileOptions.existingNotePolicy ?? .update
        let effectiveMatchWithinDeck = matchWithinDeck ?? fileOptions.matchWithinDeck ?? false
        let dataStart = sourceForRows.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        guard let dataStart else { return ImportResult() }
        let directiveSeparator = directives.first(where: { $0.lowercased().hasPrefix("#separator:") })
            .map { String($0.dropFirst("#separator:".count)).trimmingCharacters(in: .whitespaces).lowercased() }
        let directiveNotetype = directives.first(where: { $0.lowercased().hasPrefix("#notetype:") })
            .map { String($0.dropFirst("#notetype:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let directiveDeck = directives.first(where: { $0.lowercased().hasPrefix("#deck:") })
            .map { String($0.dropFirst("#deck:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let directiveColumns = directives.first(where: { $0.lowercased().hasPrefix("#columns:") })
            .map { String($0.dropFirst("#columns:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let htmlEnabled = directives.first(where: { $0.lowercased().hasPrefix("#html:") })
            .map { String($0.dropFirst("#html:".count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "false" }
            ?? allowHTML
            ?? true
        let globalTags = directives.first(where: { $0.lowercased().hasPrefix("#tags:") })
            .map { String($0.dropFirst("#tags:".count)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let directiveTags = globalTags
        let specialColumns = Self.specialColumnMap(directives).map { (name: $0.value, index: $0.key) }
        let sep = delimiter ?? separator(from: directiveSeparator) ?? detectDelimiter(dataStart)
        let defaultNotetype = notetypeID
            ?? directiveNotetype.flatMap(resolveNotetype)?.id
            ?? store.notetypes.first?.id
        guard let defaultNotetype, let defaultModel = store.notetype(id: defaultNotetype) else {
            throw CSVImportError.noNotetype
        }
        let requestedDirectiveDeck = deckID == nil ? directiveDeck.flatMap { resolveDeck($0) == nil ? $0 : nil } : nil
        var defaultDeck = deckID
            ?? directiveDeck.flatMap(resolveDeck)?.id
            ?? store.decks.first(where: { $0.name != "Default" && !$0.isFiltered })?.id
            ?? store.decks.first(where: { !$0.isFiltered })?.id
            ?? 1
        let rowText = sourceForRows.joined(separator: "\n")
        let rows = parseRows(rowText, separator: sep).filter { row in
            !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).hasPrefix("#"))
                && row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        guard !rows.isEmpty else { return ImportResult() }

        var start = 0
        let declaredColumns = directiveColumns.map { columns in
            parseColumnNames(columns, separator: sep)
        }
        var columnMap: [(field: Int?, special: String?)]? = nil
        let first = rows[0]
        if let columnMappings {
            columnMap = columnMappings.map { mapping in
                switch mapping {
                case .field(let index): return (field: index, special: nil)
                case .tags: return (field: nil, special: "tags")
                case .deck: return (field: nil, special: "deck")
                case .notetype: return (field: nil, special: "notetype")
                case .guid: return (field: nil, special: "guid")
                case .ignore: return (field: nil, special: nil)
                }
            }
            start = skipFirstRow == true ? 1 : 0
        } else if let declaredColumns {
            var regularIndex = 0
            columnMap = declaredColumns.map { header in
                let mapping = columnMapping(header, fallbackIndex: regularIndex, notetype: defaultModel)
                if mapping.special == nil { regularIndex += 1 }
                return mapping
            }
        } else if skipFirstRow == true || (skipFirstRow == nil && looksLikeHeader(first, notetype: defaultModel)) {
            var regularIndex = 0
            columnMap = first.map { header in
                let mapping = columnMapping(header, fallbackIndex: regularIndex, notetype: defaultModel)
                if mapping.special == nil { regularIndex += 1 }
                return mapping
            }
            start = 1
        } else if !specialColumns.isEmpty {
            var regularIndex = 0
            columnMap = first.indices.map { columnIndex in
                if let special = specialColumns.first(where: { $0.index == columnIndex }) {
                    return (field: nil, special: special.name)
                }
                defer { regularIndex += 1 }
                return (field: regularIndex, special: nil)
            }
        }
        if columnMappings == nil, !specialColumns.isEmpty, var map = columnMap {
            for special in specialColumns where map.indices.contains(special.index) {
                map[special.index] = (field: nil, special: special.name)
            }
            columnMap = map
        }

        var result = ImportResult()
        try store.db.exec("BEGIN IMMEDIATE")
        do {
        if let requestedDirectiveDeck {
            let created = try store.createDeck(name: requestedDirectiveDeck)
            if !created.isFiltered { defaultDeck = created.id }
        }
        for i in start..<rows.count {
            let cols = rows[i]
            guard cols.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            var model = defaultModel
            var rowDeck = defaultDeck
            var rowTags: String?
            var guid: String?
            var importedFields: [String?]
            var invalidRowNotetype = false
            if let map = columnMap {
                var values: [(Int?, String)] = []
                for (ci, mapping) in map.enumerated() where ci < cols.count {
                    if let special = mapping.special {
                        switch special {
                        case "tags":
                            rowTags = cols[ci]
                        case "deck":
                            if let deck = resolveDeck(cols[ci]) {
                                rowDeck = deck.id
                            } else if !cols[ci].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                let created = try store.createDeck(name: cols[ci])
                                if !created.isFiltered { rowDeck = created.id }
                            }
                        case "notetype":
                            let value = cols[ci].trimmingCharacters(in: .whitespacesAndNewlines)
                            if value.isEmpty {
                                model = defaultModel
                            } else if let selected = resolveNotetype(value) {
                                model = selected
                            } else {
                                invalidRowNotetype = true
                            }
                        case "guid":
                            guid = cols[ci].trimmingCharacters(in: .whitespacesAndNewlines)
                        default:
                            break
                        }
                    } else {
                        values.append((mapping.field, cols[ci]))
                    }
                }
                importedFields = Array(repeating: nil, count: model.flds.count)
                for (targetIndex, value) in values {
                    if let targetIndex, importedFields.indices.contains(targetIndex) {
                        importedFields[targetIndex] = htmlEnabled ? value : escapeHTML(value)
                    }
                }
            } else {
                importedFields = Array(repeating: nil, count: defaultModel.flds.count)
                for (ci, value) in cols.enumerated() where ci < importedFields.count {
                    importedFields[ci] = htmlEnabled ? value : escapeHTML(value)
                }
            }

            if invalidRowNotetype {
                result.ignored += 1
                continue
            }

            if let firstField = importedFields.first ?? nil,
               store.stripHTMLPreservingMediaFilenames(firstField).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.ignored += 1
                continue
            }
            let fields = importedFields.map { $0 ?? "" }
            let suppliedGUID = guid?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasGUID = !(suppliedGUID?.isEmpty ?? true)
            let matchingNotes: [AnkiNote]
            if let suppliedGUID, !suppliedGUID.isEmpty {
                matchingNotes = try store.fetchNote(guid: suppliedGUID).map { [$0] } ?? []
            } else if effectiveExistingNotePolicy == .importAsNew {
                matchingNotes = []
            } else {
                matchingNotes = try findMatchingNotes(
                    model: model,
                    fields: fields,
                    deckID: rowDeck,
                    withinDeck: effectiveMatchWithinDeck
                )
            }

            if !matchingNotes.isEmpty, effectiveExistingNotePolicy != .update {
                result.ignored += 1
                continue
            }
            if !matchingNotes.isEmpty {
                var updatedCount = 0
                for existing in matchingNotes where existing.mid == model.id {
                    let updatedFields = model.flds.indices.map { index in
                        if importedFields.indices.contains(index), let value = importedFields[index] {
                            return value
                        }
                        return index < existing.fields.count ? existing.fields[index] : ""
                    }
                    let tags = importedTags(
                        rowTags: rowTags,
                        existing: existing,
                        directiveTags: directiveTags,
                        tagsForAllNotes: tagsForAllNotes,
                        tagsForUpdatedNotes: tagsForUpdatedNotes
                    )
                    try store.updateNote(existing, fields: updatedFields, tags: tags)
                    updatedCount += 1
                }
                if updatedCount == 0 { result.ignored += 1 }
                else { result.updated += updatedCount }
            } else {
                guard importedFields.first != nil else {
                    result.ignored += 1
                    continue
                }
                let tags = importedTags(
                    rowTags: rowTags,
                    existing: nil,
                    directiveTags: directiveTags,
                    tagsForAllNotes: tagsForAllNotes,
                    tagsForUpdatedNotes: ""
                )
                try store.addNote(mid: model.id, did: rowDeck, fields: fields, tags: tags, guid: hasGUID ? suppliedGUID : nil)
                result.added += 1
            }
        }
        try store.db.exec("COMMIT")
        } catch {
            try? store.db.exec("ROLLBACK")
            try? store.reloadMeta()
            try? store.refreshCounts()
            throw error
        }
        store.notifyDeckContentAdded()
        return result
    }

    private func findMatchingNotes(model: AnkiNotetype, fields: [String], deckID: Int64, withinDeck: Bool) throws -> [AnkiNote] {
        guard let value = fields.first.map(store.normalizeNoteText), !store.stripHTMLPreservingMediaFilenames(value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let strippedValue = store.stripHTMLPreservingMediaFilenames(value)
        let checksum = store.fieldChecksum(value)
        var noteIDs: [Int64] = []
        let sql: String
        if withinDeck {
            sql = "SELECT DISTINCT n.id, n.flds FROM notes n JOIN cards c ON c.nid = n.id WHERE n.mid = ? AND n.csum = ? AND (CASE WHEN c.odid != 0 THEN c.odid ELSE c.did END) = ? ORDER BY n.id"
        } else {
            sql = "SELECT id, flds FROM notes WHERE mid = ? AND csum = ? ORDER BY id"
        }
        try store.db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, model.id)
            SQLiteDatabase.bindInt64(stmt, 2, checksum)
            if withinDeck { SQLiteDatabase.bindInt64(stmt, 3, deckID) }
        }) { stmt in
            let existingFields = SQLiteDatabase.text(stmt, 1).components(separatedBy: "\u{1f}")
            if store.stripHTMLPreservingMediaFilenames(existingFields.first ?? "") == strippedValue {
                noteIDs.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return try noteIDs.compactMap { try store.fetchNote(id: $0) }
    }

    private func importedTags(
        rowTags: String?,
        existing: AnkiNote?,
        directiveTags: String,
        tagsForAllNotes: String,
        tagsForUpdatedNotes: String
    ) -> String {
        let base = rowTags ?? existing?.tagList.joined(separator: " ") ?? ""
        return [base, directiveTags, tagsForAllNotes, tagsForUpdatedNotes]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private func detectDelimiter(_ line: String) -> Character {
        let tabs = line.filter { $0 == "\t" }.count
        let commas = line.filter { $0 == "," }.count
        let semis = line.filter { $0 == ";" }.count
        if tabs >= commas && tabs >= semis && tabs > 0 { return "\t" }
        if semis > commas { return ";" }
        return ","
    }

    private func resolveDeck(_ value: String) -> AnkiDeck? {
        if let id = Int64(value), let deck = store.deck(id: id), !deck.isFiltered { return deck }
        return store.decks.first { $0.name.caseInsensitiveCompare(value) == .orderedSame && !$0.isFiltered }
    }

    private func resolveNotetype(_ value: String) -> AnkiNotetype? {
        if let id = Int64(value), let notetype = store.notetype(id: id) { return notetype }
        return store.notetypes.first { $0.name.caseInsensitiveCompare(value) == .orderedSame }
    }

    private func separator(from directive: String?) -> Character? {
        switch directive {
        case "tab": return "\t"
        case "comma": return ","
        case "semicolon": return ";"
        case "space": return " "
        case "pipe": return "|"
        case "colon": return ":"
        default: return directive.flatMap { $0.count == 1 ? $0.first : nil }
        }
    }

    private func looksLikeHeader(_ cols: [String], notetype: AnkiNotetype) -> Bool {
        let names = Set(notetype.flds.map { $0.name.lowercased() } + ["tags", "deck", "notetype", "guid"])
        let hits = cols.filter { names.contains($0.lowercased()) }.count
        return hits >= 1 && hits >= cols.count / 2
    }

    private func columnMapping(_ rawHeader: String, fallbackIndex: Int, notetype: AnkiNotetype) -> (field: Int?, special: String?) {
        let header = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = header.lowercased()
        if ["tags", "deck", "notetype", "guid"].contains(lower) { return (nil, lower) }
        let index = notetype.flds.firstIndex(where: { $0.name.caseInsensitiveCompare(header) == .orderedSame }) ?? fallbackIndex
        return (index, nil)
    }

    private static func specialColumnMap(_ directives: [String]) -> [Int: String] {
        var columns: [Int: String] = [:]
        for name in ["notetype", "deck", "tags", "guid"] {
            guard let line = directives.first(where: { $0.lowercased().hasPrefix("#\(name) column:") }),
                  let index = Int(line.dropFirst("#\(name) column:".count).trimmingCharacters(in: .whitespacesAndNewlines)),
                  index > 0 else { continue }
            columns[index - 1] = name
        }
        return columns
    }

    private func parseRows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "#", !inQuotes, fields.isEmpty, current.isEmpty,
               i == text.startIndex || text[text.index(before: i)] == "\n" {
                while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            if ch == "\"" {
                let next = text.index(after: i)
                if inQuotes && next < text.endIndex && text[next] == "\"" {
                    current.append("\"")
                    i = text.index(after: next)
                    continue
                }
                inQuotes.toggle()
                i = text.index(after: i)
                continue
            }
            if ch == separator && !inQuotes {
                fields.append(current)
                current = ""
                i = text.index(after: i)
                continue
            }
            if ch == "\n" && !inQuotes {
                fields.append(current)
                rows.append(fields)
                fields = []
                current = ""
                i = text.index(after: i)
                continue
            }
            current.append(ch)
            i = text.index(after: i)
        }
        fields.append(current)
        rows.append(fields)
        return rows
    }

    private func parseColumnNames(_ value: String, separator: Character) -> [String] {
        let columnSeparator: Character = value.contains(separator) ? separator : ","
        return parseRows(value, separator: columnSeparator).first ?? []
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
