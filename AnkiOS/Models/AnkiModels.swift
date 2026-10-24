import Foundation

struct AnkiNote: Identifiable, Hashable, Sendable {
    var id: Int64
    var guid: String
    var mid: Int64
    var mod: Int64
    var usn: Int
    var tags: String
    var flds: String
    var sfld: String
    var csum: Int64
    var flags: Int
    var data: String

    var fields: [String] {
        flds.components(separatedBy: "\u{1f}")
    }

    var tagList: [String] {
        AnkiTag.split(tags)
    }
}

struct AddNoteCopyRequest: Equatable {
    var note: AnkiNote
    var deckID: Int64
}

enum AnkiTag {
    static func split(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }).map(String.init)
    }

    static func key(_ value: String) -> String {
        value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func canonicalized(_ value: String, existing: [String]) -> [String] {
        var names: [String: String] = [:]
        for name in existing.sorted() where names[key(name)] == nil { names[key(name)] = name }
        var parents = names
        func registerParents(_ name: String) {
            let parts = name.components(separatedBy: "::")
            for count in 1...parts.count {
                let prefix = parts.prefix(count).joined(separator: "::")
                if parents[key(prefix)] == nil { parents[key(prefix)] = prefix }
            }
        }
        for name in existing.sorted() { registerParents(name) }
        var result: [String: String] = [:]
        for raw in split(value) {
            var parts = raw.components(separatedBy: "::").map { part in
                let scalars = part.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
                    !($0.value < 32 || $0.value == 127 || $0 == " " || $0.value == 0x3000)
                }
                let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "blank" : trimmed
            }
            var name = parts.joined(separator: "::")
            if let registered = names[key(name)] {
                name = registered
            } else {
                if parts.count > 1 {
                    for count in stride(from: parts.count - 1, through: 1, by: -1) {
                        let prefix = parts.prefix(count).joined(separator: "::")
                        if let parent = parents[key(prefix)] {
                            parts = parent.components(separatedBy: "::") + Array(parts.dropFirst(count))
                            name = parts.joined(separator: "::")
                            break
                        }
                    }
                }
                names[key(name)] = name
                registerParents(name)
            }
            if result[key(name)] == nil { result[key(name)] = name }
        }
        return result.values.sorted { key($0) < key($1) }
    }

    static func join(_ values: [String]) -> String {
        values.isEmpty ? "" : " \(values.joined(separator: " ")) "
    }

    static func replacingPrefix(_ tag: String, from prefix: String, to replacement: String) -> String? {
        let parts = tag.components(separatedBy: "::")
        let count = prefix.components(separatedBy: "::").count
        guard parts.count >= count, key(parts.prefix(count).joined(separator: "::")) == key(prefix) else { return nil }
        let suffix = parts.dropFirst(count).joined(separator: "::")
        return replacement + (suffix.isEmpty ? "" : "::" + suffix)
    }
}

struct AnkiCard: Identifiable, Hashable, Sendable {
    var id: Int64
    var nid: Int64
    var did: Int64
    var ord: Int
    var mod: Int64
    var usn: Int
    var type: Int
    var queue: Int
    var due: Int
    var ivl: Int
    var factor: Int
    var reps: Int
    var lapses: Int
    var left: Int
    var odue: Int
    var odid: Int64
    var flags: Int
    var data: String

    enum CardType: Int {
        case new = 0
        case learning = 1
        case review = 2
        case relearning = 3
    }

    enum Queue: Int {
        case new = 0
        case learning = 1
        case review = 2
        case dayLearn = 3
        case preview = 4
        case suspended = -1
        case siblingBuried = -2
        case manuallyBuried = -3
    }

    var cardType: CardType { CardType(rawValue: type) ?? .new }
    var queueKind: Queue { Queue(rawValue: queue) ?? .new }
}

struct AnkiDeck: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var mod: Int64
    var usn: Int
    var collapsed: Bool
    var browserCollapsed: Bool
    var desc: String
    var markdownDescription: Bool = false
    var dyn: Int
    var conf: Int64
    var desiredRetention: Double? = nil
    var newLimit: Int? = nil
    var reviewLimit: Int? = nil
    var newLimitToday: AnkiDayLimit? = nil
    var reviewLimitToday: AnkiDayLimit? = nil
    var extendNew: Int
    var extendRev: Int
    var newToday: [Int]
    var revToday: [Int]
    var lrnToday: [Int]
    var timeToday: [Int]
    /// Filtered deck search string (first term) when dyn == 1
    var searchTerms: String?
    var termLimit: Int?
    var resched: Bool?
    var previewDelay: Int?
    /// Anki filtered-deck gather order: `due`, `added`, or `random`.
    var searchOrder: String? = nil
    /// Space-separated tags the filtered search must include (any) or exclude.
    var includeTags: String? = nil
    var excludeTags: String? = nil
    /// Preview delays in seconds when a filtered deck does not reschedule.
    var previewAgain: Int? = nil
    var previewHard: Int? = nil
    var previewGood: Int? = nil
    /// Second filtered-deck search, the way Anki stores `terms[1]`.
    var searchTerms2: String? = nil
    var termLimit2: Int? = nil
    var searchOrder2: String? = nil
    var other: [String: AnyCodable] = [:]

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AnkiDeck, rhs: AnkiDeck) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.mod == rhs.mod && lhs.dyn == rhs.dyn
            && lhs.desiredRetention == rhs.desiredRetention
            && lhs.newLimit == rhs.newLimit && lhs.reviewLimit == rhs.reviewLimit
            && lhs.newLimitToday == rhs.newLimitToday && lhs.reviewLimitToday == rhs.reviewLimitToday
    }

    var displayName: String {
        if id == 1, name.localizedCaseInsensitiveCompare("Default") == .orderedSame {
            return "Padrão"
        }
        return name.split(separator: ":").last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            ?? name.components(separatedBy: "::").last
            ?? name
    }

    var pathComponents: [String] {
        name.components(separatedBy: "::")
    }

    var parentName: String? {
        let parts = pathComponents
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "::")
    }

    var isFiltered: Bool { dyn == 1 }
}

struct AnkiDayLimit: Codable, Hashable, Sendable {
    var limit: Int
    var today: Int
}

struct AnkiField: Hashable, Codable, Sendable {
    var id: Int64?
    var tag: Int?
    var name: String
    var ord: Int
    var sticky: Bool
    var rtl: Bool
    var font: String
    var size: Int
    var description: String
    var plainText: Bool
    var collapsed: Bool
    var excludeFromSearch: Bool
    var preventDeletion: Bool
    var other: [String: AnyCodable]

    static func normalizedName(_ name: String) -> String? {
        let invalidCharacters = CharacterSet(charactersIn: ":{}\"")
        let cleaned = String(name.unicodeScalars.filter { !invalidCharacters.contains($0) })
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = String(trimmed.drop(while: { character in
            character == "#" || character == "/" || character == "^" || character.isWhitespace
        }))
        return normalized.isEmpty ? nil : normalized
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, tag, name, ord, sticky, rtl, font, size, description, plainText, collapsed, excludeFromSearch, preventDeletion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        tag = try c.decodeIfPresent(Int.self, forKey: .tag)
        name = try c.decode(String.self, forKey: .name)
        ord = try c.decodeIfPresent(Int.self, forKey: .ord) ?? 0
        sticky = try c.decodeIfPresent(Bool.self, forKey: .sticky) ?? false
        rtl = try c.decodeIfPresent(Bool.self, forKey: .rtl) ?? false
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? "Arial"
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 20
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        plainText = try c.decodeIfPresent(Bool.self, forKey: .plainText) ?? false
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        excludeFromSearch = try c.decodeIfPresent(Bool.self, forKey: .excludeFromSearch) ?? false
        preventDeletion = try c.decodeIfPresent(Bool.self, forKey: .preventDeletion) ?? false
        other = try decodeExtraFields(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    init(id: Int64? = nil, tag: Int? = nil, name: String, ord: Int, sticky: Bool = false, rtl: Bool = false, font: String = "Arial", size: Int = 20,
         description: String = "", plainText: Bool = false, collapsed: Bool = false, excludeFromSearch: Bool = false, preventDeletion: Bool = false,
         other: [String: AnyCodable] = [:]) {
        self.id = id
        self.tag = tag
        self.name = name
        self.ord = ord
        self.sticky = sticky
        self.rtl = rtl
        self.font = font
        self.size = size
        self.description = description
        self.plainText = plainText
        self.collapsed = collapsed
        self.excludeFromSearch = excludeFromSearch
        self.preventDeletion = preventDeletion
        self.other = other
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(tag, forKey: .tag)
        try c.encode(name, forKey: .name)
        try c.encode(ord, forKey: .ord)
        try c.encode(sticky, forKey: .sticky)
        try c.encode(rtl, forKey: .rtl)
        try c.encode(font, forKey: .font)
        try c.encode(size, forKey: .size)
        try c.encode(description, forKey: .description)
        try c.encode(plainText, forKey: .plainText)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encode(excludeFromSearch, forKey: .excludeFromSearch)
        try c.encode(preventDeletion, forKey: .preventDeletion)
        try encodeExtraFields(other, to: encoder)
    }
}

struct AnkiTemplate: Hashable, Codable, Sendable {
    var id: Int64?
    var name: String
    var ord: Int
    var qfmt: String
    var afmt: String
    var bqfmt: String
    var bafmt: String
    var did: Int64?
    var bfont: String
    var bsize: Int
    var other: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, ord, qfmt, afmt, bqfmt, bafmt, did, bfont, bsize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        ord = try c.decodeIfPresent(Int.self, forKey: .ord) ?? 0
        qfmt = try c.decodeIfPresent(String.self, forKey: .qfmt) ?? ""
        afmt = try c.decodeIfPresent(String.self, forKey: .afmt) ?? ""
        bqfmt = try c.decodeIfPresent(String.self, forKey: .bqfmt) ?? ""
        bafmt = try c.decodeIfPresent(String.self, forKey: .bafmt) ?? ""
        did = try c.decodeIfPresent(Int64.self, forKey: .did)
        bfont = try c.decodeIfPresent(String.self, forKey: .bfont) ?? ""
        bsize = try c.decodeIfPresent(Int.self, forKey: .bsize) ?? 0
        other = try decodeExtraFields(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    init(id: Int64? = nil, name: String, ord: Int, qfmt: String, afmt: String, bqfmt: String = "", bafmt: String = "",
         did: Int64? = nil, bfont: String = "", bsize: Int = 0, other: [String: AnyCodable] = [:]) {
        self.id = id
        self.name = name
        self.ord = ord
        self.qfmt = qfmt
        self.afmt = afmt
        self.bqfmt = bqfmt
        self.bafmt = bafmt
        self.did = did
        self.bfont = bfont
        self.bsize = bsize
        self.other = other
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(ord, forKey: .ord)
        try c.encode(qfmt, forKey: .qfmt)
        try c.encode(afmt, forKey: .afmt)
        try c.encode(bqfmt, forKey: .bqfmt)
        try c.encode(bafmt, forKey: .bafmt)
        try c.encodeIfPresent(did, forKey: .did)
        try c.encode(bfont, forKey: .bfont)
        try c.encode(bsize, forKey: .bsize)
        try encodeExtraFields(other, to: encoder)
    }
}

struct AnkiNotetype: Identifiable, Hashable, Codable, Sendable {
    static let defaultLatexPre = #"""
    \documentclass[12pt]{article}
    \special{papersize=3in,5in}
    \usepackage[utf8]{inputenc}
    \usepackage{amssymb,amsmath}
    \pagestyle{empty}
    \setlength{\parindent}{0in}
    \begin{document}
    """#
    static let defaultLatexPost = #"\end{document}"#

    var id: Int64
    var name: String
    var type: Int
    var mod: Int64
    var usn: Int
    var sortf: Int
    var did: Int64?
    var tmpls: [AnkiTemplate]
    var flds: [AnkiField]
    var css: String
    var latexPre: String
    var latexPost: String
    var latexsvg: Bool
    var req: [[AnyCodable]]?
    var tags: [String]
    var vers: [Int]
    var other: [String: AnyCodable]

    var isCloze: Bool { type == 1 }

    mutating func assignMissingComponentIDs() {
        var fieldIDs = Set(flds.compactMap(\.id))
        for index in flds.indices where flds[index].id == nil {
            var id = Int64.random(in: 1...Int64.max)
            while !fieldIDs.insert(id).inserted { id = Int64.random(in: 1...Int64.max) }
            flds[index].id = id
        }
        var templateIDs = Set(tmpls.compactMap(\.id))
        for index in tmpls.indices where tmpls[index].id == nil {
            var id = Int64.random(in: 1...Int64.max)
            while !templateIDs.insert(id).inserted { id = Int64.random(in: 1...Int64.max) }
            tmpls[index].id = id
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, type, mod, usn, sortf, did, tmpls, flds, css
        case latexPre, latexPost, latexsvg, req, tags, vers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Anki stores id as string key externally; inside JSON id is number
        if let n = try? c.decode(Int64.self, forKey: .id) {
            id = n
        } else if let s = try? c.decode(String.self, forKey: .id), let n = Int64(s) {
            id = n
        } else {
            id = 0
        }
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(Int.self, forKey: .type) ?? 0
        mod = try c.decodeIfPresent(Int64.self, forKey: .mod) ?? 0
        usn = try c.decodeIfPresent(Int.self, forKey: .usn) ?? -1
        sortf = try c.decodeIfPresent(Int.self, forKey: .sortf) ?? 0
        did = try c.decodeIfPresent(Int64.self, forKey: .did)
        tmpls = try c.decodeIfPresent([AnkiTemplate].self, forKey: .tmpls) ?? []
        flds = try c.decodeIfPresent([AnkiField].self, forKey: .flds) ?? []
        css = try c.decodeIfPresent(String.self, forKey: .css) ?? ""
        latexPre = try c.decodeIfPresent(String.self, forKey: .latexPre) ?? Self.defaultLatexPre
        latexPost = try c.decodeIfPresent(String.self, forKey: .latexPost) ?? Self.defaultLatexPost
        latexsvg = try c.decodeIfPresent(Bool.self, forKey: .latexsvg) ?? false
        // req is heterogeneous; never fail the whole notetype on it
        req = (try? c.decodeIfPresent([[AnyCodable]].self, forKey: .req)) ?? nil
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        vers = try c.decodeIfPresent([Int].self, forKey: .vers) ?? []
        other = try decodeExtraFields(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(mod, forKey: .mod)
        try c.encode(usn, forKey: .usn)
        try c.encode(sortf, forKey: .sortf)
        try c.encodeIfPresent(did, forKey: .did)
        try c.encode(tmpls, forKey: .tmpls)
        try c.encode(flds, forKey: .flds)
        try c.encode(css, forKey: .css)
        try c.encode(latexPre, forKey: .latexPre)
        try c.encode(latexPost, forKey: .latexPost)
        try c.encode(latexsvg, forKey: .latexsvg)
        try c.encodeIfPresent(req, forKey: .req)
        try c.encode(tags, forKey: .tags)
        try c.encode(vers, forKey: .vers)
        try encodeExtraFields(other, to: encoder)
    }

    init(id: Int64, name: String, type: Int = 0, mod: Int64 = 0, usn: Int = -1, sortf: Int = 0,
         did: Int64? = nil, tmpls: [AnkiTemplate], flds: [AnkiField], css: String = defaultCSS,
         latexPre: String = AnkiNotetype.defaultLatexPre, latexPost: String = AnkiNotetype.defaultLatexPost, latexsvg: Bool = false,
         req: [[AnyCodable]]? = nil, tags: [String] = [], vers: [Int] = [], other: [String: AnyCodable] = [:]) {
        self.id = id
        self.name = name
        self.type = type
        self.mod = mod
        self.usn = usn
        self.sortf = sortf
        self.did = did
        self.tmpls = tmpls
        self.flds = flds
        self.css = css
        self.latexPre = latexPre
        self.latexPost = latexPost
        self.latexsvg = latexsvg
        self.req = req
        self.tags = tags
        self.vers = vers
        self.other = other
    }

    static let defaultCSS = """
    .card {
      font-family: arial;
      font-size: 20px;
      text-align: center;
      color: black;
      background-color: white;
    }
    """
}

enum NotetypeEditMapping {
    static func transferNoteFieldValues(_ values: [String], from original: AnkiNotetype, to edited: AnkiNotetype) -> [String] {
        let oldFields = original.flds.sorted { $0.ord < $1.ord }
        let newFields = edited.flds.sorted { $0.ord < $1.ord }
        var result = Array(repeating: "", count: (newFields.map(\.ord).max() ?? -1) + 1)
        var copiedFieldNames = Set<String>()

        for newField in newFields {
            guard let oldField = oldFields.first(where: { $0.name == newField.name }),
                  values.indices.contains(oldField.ord),
                  !values[oldField.ord].isEmpty else { continue }
            result[newField.ord] = values[oldField.ord]
            copiedFieldNames.insert(newField.name)
        }

        var newIndex = 0
        for oldField in oldFields {
            while newIndex < newFields.count && copiedFieldNames.contains(newFields[newIndex].name) {
                newIndex += 1
            }
            guard newIndex < newFields.count else { break }
            guard !copiedFieldNames.contains(oldField.name), values.indices.contains(oldField.ord) else { continue }
            let value = values[oldField.ord]
            guard !value.isEmpty else { continue }
            result[newFields[newIndex].ord] = value
            newIndex += 1
        }

        return result
    }

    static func renamingFields(in template: String, names: [String: String], removed: Set<String> = []) -> String {
        guard !names.isEmpty || !removed.isEmpty, let regex = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#) else { return template }
        var result = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: template), let fullRange = Range(match.range, in: result) else { continue }
            let token = template[tokenRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix: String
            let fieldName: String
            if let first = token.first, "#^/".contains(first) {
                prefix = String(first)
                fieldName = String(token.dropFirst())
            } else if let colon = token.lastIndex(of: ":") {
                prefix = String(token[...colon])
                fieldName = String(token[token.index(after: colon)...])
            } else {
                prefix = ""
                fieldName = token
            }
            if removed.contains(fieldName) {
                result.replaceSubrange(fullRange, with: "")
            } else if let name = names[fieldName] {
                result.replaceSubrange(fullRange, with: "{{\(prefix)\(name)}}")
            }
        }
        return result
    }

    static func fields(from original: AnkiNotetype, to edited: AnkiNotetype) -> [Int: Int] {
        sources(old: original.flds.map { ($0.id, $0.ord, $0.name) }, new: edited.flds.map { ($0.id, $0.ord, $0.name) })
    }

    static func templates(from original: AnkiNotetype, to edited: AnkiNotetype) -> [Int: Int] {
        sources(old: original.tmpls.map { ($0.id, $0.ord, $0.name) }, new: edited.tmpls.map { ($0.id, $0.ord, $0.name) })
    }

    private static func sources(old: [(id: Int64?, ord: Int, name: String)], new: [(id: Int64?, ord: Int, name: String)]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var used = Set<Int>()
        for item in new {
            let source = old.first { candidate in
                guard !used.contains(candidate.ord) else { return false }
                if let id = item.id { return candidate.id == id }
                return candidate.id == nil && candidate.name == item.name
            }
            if let source {
                result[item.ord] = source.ord
                used.insert(source.ord)
            }
        }
        for item in new where item.id == nil && result[item.ord] == nil {
            if let source = old.first(where: { $0.id == nil && $0.ord == item.ord && !used.contains($0.ord) }) {
                result[item.ord] = source.ord
                used.insert(source.ord)
            }
        }
        return result
    }
}

struct AnkiDeckConfig: Identifiable, Hashable, Codable, Sendable {
    var id: Int64
    var name: String
    var mod: Int64
    var usn: Int
    var maxTaken: Int
    var autoplay: Bool
    var timer: Int
    var stopTimerOnAnswer: Bool
    var replayq: Bool
    var new: NewConfig
    var rev: RevConfig
    var lapse: LapseConfig
    var dyn: Bool
    var newMix: Int
    var newPerDayMinimum: Int
    var interdayLearningMix: Int
    var reviewOrder: Int
    var newSortOrder: Int
    var newGatherPriority: Int
    var buryInterdayLearning: Bool
    var fsrsWeights: [Double]?
    var fsrsParams5: [Double]?
    var fsrsParams6: [Double]?
    var desiredRetention: Double?
    var historicalRetention: Double
    var ignoreRevlogsBeforeDate: String?
    var paramSearch: String?
    var secondsToShowQuestion: Double
    var secondsToShowAnswer: Double
    var questionAction: Int
    var answerAction: Int
    var waitForAudio: Bool
    /// Monday…Sunday. 1 normal, 0.5 reduced, 0 minimum. Empty means every day is normal.
    var easyDayPercents: [Double]
    var other: [String: AnyCodable] = [:]

    var activeFSRSWeights: [Double]? {
        fsrsParams6 ?? fsrsParams5 ?? fsrsWeights
    }

    struct NewConfig: Hashable, Codable, Sendable {
        var delays: [Double]
        var ints: [Int]
        var initialFactor: Int
        var order: Int
        var perDay: Int
        var bury: Bool
        var other: [String: AnyCodable] = [:]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case delays, ints, initialFactor, order, perDay, bury
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            delays = try c.decodeIfPresent([Double].self, forKey: .delays) ?? [1, 10]
            ints = try c.decodeIfPresent([Int].self, forKey: .ints) ?? [1, 4]
            initialFactor = try c.decodeIfPresent(Int.self, forKey: .initialFactor) ?? 2500
            order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 1
            perDay = try c.decodeIfPresent(Int.self, forKey: .perDay) ?? 20
            bury = try c.decodeIfPresent(Bool.self, forKey: .bury) ?? false
            other = try decodeExtraFields(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        init(delays: [Double] = [1, 10], ints: [Int] = [1, 4], initialFactor: Int = 2500,
             order: Int = 1, perDay: Int = 20, bury: Bool = false) {
            self.delays = delays
            self.ints = ints
            self.initialFactor = initialFactor
            self.order = order
            self.perDay = perDay
            self.bury = bury
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(delays, forKey: .delays)
            try c.encode(ints, forKey: .ints)
            try c.encode(initialFactor, forKey: .initialFactor)
            try c.encode(order, forKey: .order)
            try c.encode(perDay, forKey: .perDay)
            try c.encode(bury, forKey: .bury)
            try encodeExtraFields(other, to: encoder)
        }
    }

    struct RevConfig: Hashable, Codable, Sendable {
        var perDay: Int
        var ease4: Double
        var fuzz: Double
        var minSpace: Int
        var ivlFct: Double
        var maxIvl: Int
        var bury: Bool
        var hardFactor: Double
        var other: [String: AnyCodable] = [:]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            perDay = try c.decodeIfPresent(Int.self, forKey: .perDay) ?? 200
            ease4 = try c.decodeIfPresent(Double.self, forKey: .ease4) ?? 1.3
            fuzz = try c.decodeIfPresent(Double.self, forKey: .fuzz) ?? 0.05
            minSpace = try c.decodeIfPresent(Int.self, forKey: .minSpace) ?? 1
            ivlFct = try c.decodeIfPresent(Double.self, forKey: .ivlFct) ?? 1.0
            maxIvl = try c.decodeIfPresent(Int.self, forKey: .maxIvl) ?? 36500
            bury = try c.decodeIfPresent(Bool.self, forKey: .bury) ?? false
            hardFactor = try c.decodeIfPresent(Double.self, forKey: .hardFactor) ?? 1.2
            other = try decodeExtraFields(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case perDay, ease4, fuzz, minSpace, ivlFct, maxIvl, bury, hardFactor
        }

        init(perDay: Int = 200, ease4: Double = 1.3, fuzz: Double = 0.05, minSpace: Int = 1,
             ivlFct: Double = 1.0, maxIvl: Int = 36500, bury: Bool = false, hardFactor: Double = 1.2) {
            self.perDay = perDay
            self.ease4 = ease4
            self.fuzz = fuzz
            self.minSpace = minSpace
            self.ivlFct = ivlFct
            self.maxIvl = maxIvl
            self.bury = bury
            self.hardFactor = hardFactor
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(perDay, forKey: .perDay)
            try c.encode(ease4, forKey: .ease4)
            try c.encode(fuzz, forKey: .fuzz)
            try c.encode(minSpace, forKey: .minSpace)
            try c.encode(ivlFct, forKey: .ivlFct)
            try c.encode(maxIvl, forKey: .maxIvl)
            try c.encode(bury, forKey: .bury)
            try c.encode(hardFactor, forKey: .hardFactor)
            try encodeExtraFields(other, to: encoder)
        }
    }

    struct LapseConfig: Hashable, Codable, Sendable {
        var delays: [Double]
        var mult: Double
        var minInt: Int
        var leechFails: Int
        var leechAction: Int
        var other: [String: AnyCodable] = [:]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            delays = try c.decodeIfPresent([Double].self, forKey: .delays) ?? [10]
            mult = try c.decodeIfPresent(Double.self, forKey: .mult) ?? 0
            minInt = try c.decodeIfPresent(Int.self, forKey: .minInt) ?? 1
            leechFails = try c.decodeIfPresent(Int.self, forKey: .leechFails) ?? 8
            leechAction = try c.decodeIfPresent(Int.self, forKey: .leechAction) ?? 0
            other = try decodeExtraFields(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case delays, mult, minInt, leechFails, leechAction
        }

        init(delays: [Double] = [10], mult: Double = 0, minInt: Int = 1, leechFails: Int = 8, leechAction: Int = 0) {
            self.delays = delays
            self.mult = mult
            self.minInt = minInt
            self.leechFails = leechFails
            self.leechAction = leechAction
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(delays, forKey: .delays)
            try c.encode(mult, forKey: .mult)
            try c.encode(minInt, forKey: .minInt)
            try c.encode(leechFails, forKey: .leechFails)
            try c.encode(leechAction, forKey: .leechAction)
            try encodeExtraFields(other, to: encoder)
        }
    }

    static func `default`(id: Int64 = 1) -> AnkiDeckConfig {
        AnkiDeckConfig(
            id: id,
            name: "Default",
            mod: Int64(Date().timeIntervalSince1970),
            usn: -1,
            maxTaken: 60,
            autoplay: true,
            timer: 0,
            stopTimerOnAnswer: false,
            replayq: true,
            new: .init(),
            rev: .init(),
            lapse: .init(),
            dyn: false,
            newMix: 0,
            newPerDayMinimum: 0,
            interdayLearningMix: 0,
            reviewOrder: 0,
            newSortOrder: 0,
            newGatherPriority: 0,
            buryInterdayLearning: false,
            fsrsWeights: nil,
            desiredRetention: 0.9,
            historicalRetention: 0.9,
            ignoreRevlogsBeforeDate: nil,
            secondsToShowQuestion: 0,
            secondsToShowAnswer: 0,
            questionAction: 0,
            answerAction: 0,
            waitForAudio: true,
            fsrsParams5: nil,
            fsrsParams6: nil,
            easyDayPercents: []
        )
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, mod, usn, maxTaken, autoplay, timer, stopTimerOnAnswer, replayq, new, rev, lapse, dyn
        case newMix, newPerDayMinimum, interdayLearningMix, reviewOrder, newSortOrder, newGatherPriority
        case buryInterdayLearning, fsrsWeights, fsrsParams5, fsrsParams6, desiredRetention, historicalRetention, ignoreRevlogsBeforeDate, paramSearch
        case secondsToShowQuestion, secondsToShowAnswer, questionAction, answerAction, waitForAudio
        case easyDayPercents = "easyDaysPercentages"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try? c.decode(Int64.self, forKey: .id) {
            id = n
        } else if let s = try? c.decode(String.self, forKey: .id), let n = Int64(s) {
            id = n
        } else {
            id = 1
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Default"
        mod = try c.decodeIfPresent(Int64.self, forKey: .mod) ?? 0
        usn = try c.decodeIfPresent(Int.self, forKey: .usn) ?? -1
        maxTaken = try c.decodeIfPresent(Int.self, forKey: .maxTaken) ?? 60
        autoplay = try c.decodeIfPresent(Bool.self, forKey: .autoplay) ?? true
        timer = try c.decodeIfPresent(Int.self, forKey: .timer) ?? 0
        stopTimerOnAnswer = try c.decodeIfPresent(Bool.self, forKey: .stopTimerOnAnswer) ?? false
        replayq = try c.decodeIfPresent(Bool.self, forKey: .replayq) ?? true
        new = try c.decodeIfPresent(NewConfig.self, forKey: .new) ?? .init()
        rev = try c.decodeIfPresent(RevConfig.self, forKey: .rev) ?? .init()
        lapse = try c.decodeIfPresent(LapseConfig.self, forKey: .lapse) ?? .init()
        dyn = try c.decodeIfPresent(Bool.self, forKey: .dyn) ?? false
        newMix = try c.decodeIfPresent(Int.self, forKey: .newMix) ?? 0
        newPerDayMinimum = try c.decodeIfPresent(Int.self, forKey: .newPerDayMinimum) ?? 0
        interdayLearningMix = try c.decodeIfPresent(Int.self, forKey: .interdayLearningMix) ?? 0
        reviewOrder = try c.decodeIfPresent(Int.self, forKey: .reviewOrder) ?? 0
        newSortOrder = try c.decodeIfPresent(Int.self, forKey: .newSortOrder) ?? 0
        newGatherPriority = try c.decodeIfPresent(Int.self, forKey: .newGatherPriority) ?? 0
        buryInterdayLearning = try c.decodeIfPresent(Bool.self, forKey: .buryInterdayLearning) ?? false
        fsrsWeights = try c.decodeIfPresent([Double].self, forKey: .fsrsWeights)
        fsrsParams5 = try c.decodeIfPresent([Double].self, forKey: .fsrsParams5)
        fsrsParams6 = try c.decodeIfPresent([Double].self, forKey: .fsrsParams6)
        desiredRetention = try c.decodeIfPresent(Double.self, forKey: .desiredRetention)
        historicalRetention = try c.decodeIfPresent(Double.self, forKey: .historicalRetention) ?? 0.9
        ignoreRevlogsBeforeDate = try c.decodeIfPresent(String.self, forKey: .ignoreRevlogsBeforeDate)
        paramSearch = try c.decodeIfPresent(String.self, forKey: .paramSearch)
        secondsToShowQuestion = try c.decodeIfPresent(Double.self, forKey: .secondsToShowQuestion) ?? 0
        secondsToShowAnswer = try c.decodeIfPresent(Double.self, forKey: .secondsToShowAnswer) ?? 0
        questionAction = try c.decodeIfPresent(Int.self, forKey: .questionAction) ?? 0
        answerAction = try c.decodeIfPresent(Int.self, forKey: .answerAction) ?? 0
        waitForAudio = try c.decodeIfPresent(Bool.self, forKey: .waitForAudio) ?? true
        easyDayPercents = try c.decodeIfPresent([Double].self, forKey: .easyDayPercents) ?? []
        other = try decodeExtraFields(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    init(id: Int64, name: String, mod: Int64, usn: Int, maxTaken: Int, autoplay: Bool, timer: Int, stopTimerOnAnswer: Bool = false, replayq: Bool,
         new: NewConfig, rev: RevConfig, lapse: LapseConfig, dyn: Bool, newMix: Int, newPerDayMinimum: Int,
         interdayLearningMix: Int, reviewOrder: Int, newSortOrder: Int, newGatherPriority: Int,
         buryInterdayLearning: Bool, fsrsWeights: [Double]?, desiredRetention: Double?, historicalRetention: Double = 0.9, ignoreRevlogsBeforeDate: String?,
         paramSearch: String? = nil, secondsToShowQuestion: Double = 0, secondsToShowAnswer: Double = 0,
         questionAction: Int = 0, answerAction: Int = 0, waitForAudio: Bool = true,
         fsrsParams5: [Double]? = nil, fsrsParams6: [Double]? = nil,
         easyDayPercents: [Double] = [], other: [String: AnyCodable] = [:]) {
        self.id = id
        self.name = name
        self.mod = mod
        self.usn = usn
        self.maxTaken = maxTaken
        self.autoplay = autoplay
        self.timer = timer
        self.stopTimerOnAnswer = stopTimerOnAnswer
        self.replayq = replayq
        self.new = new
        self.rev = rev
        self.lapse = lapse
        self.dyn = dyn
        self.newMix = newMix
        self.newPerDayMinimum = newPerDayMinimum
        self.interdayLearningMix = interdayLearningMix
        self.reviewOrder = reviewOrder
        self.newSortOrder = newSortOrder
        self.newGatherPriority = newGatherPriority
        self.buryInterdayLearning = buryInterdayLearning
        self.fsrsWeights = fsrsWeights
        self.fsrsParams5 = fsrsParams5
        self.fsrsParams6 = fsrsParams6
        self.desiredRetention = desiredRetention
        self.historicalRetention = historicalRetention
        self.ignoreRevlogsBeforeDate = ignoreRevlogsBeforeDate
        self.paramSearch = paramSearch
        self.secondsToShowQuestion = secondsToShowQuestion
        self.secondsToShowAnswer = secondsToShowAnswer
        self.questionAction = questionAction
        self.answerAction = answerAction
        self.waitForAudio = waitForAudio
        self.easyDayPercents = easyDayPercents
        self.other = other
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(mod, forKey: .mod)
        try c.encode(usn, forKey: .usn)
        try c.encode(maxTaken, forKey: .maxTaken)
        try c.encode(autoplay, forKey: .autoplay)
        try c.encode(timer, forKey: .timer)
        try c.encode(stopTimerOnAnswer, forKey: .stopTimerOnAnswer)
        try c.encode(replayq, forKey: .replayq)
        try c.encode(new, forKey: .new)
        try c.encode(rev, forKey: .rev)
        try c.encode(lapse, forKey: .lapse)
        try c.encode(dyn, forKey: .dyn)
        try c.encode(newMix, forKey: .newMix)
        try c.encode(newPerDayMinimum, forKey: .newPerDayMinimum)
        try c.encode(interdayLearningMix, forKey: .interdayLearningMix)
        try c.encode(reviewOrder, forKey: .reviewOrder)
        try c.encode(newSortOrder, forKey: .newSortOrder)
        try c.encode(newGatherPriority, forKey: .newGatherPriority)
        try c.encode(buryInterdayLearning, forKey: .buryInterdayLearning)
        try c.encodeIfPresent(fsrsWeights, forKey: .fsrsWeights)
        try c.encodeIfPresent(fsrsParams5, forKey: .fsrsParams5)
        try c.encodeIfPresent(fsrsParams6, forKey: .fsrsParams6)
        try c.encodeIfPresent(desiredRetention, forKey: .desiredRetention)
        try c.encode(historicalRetention, forKey: .historicalRetention)
        try c.encodeIfPresent(ignoreRevlogsBeforeDate, forKey: .ignoreRevlogsBeforeDate)
        try c.encodeIfPresent(paramSearch, forKey: .paramSearch)
        try c.encode(secondsToShowQuestion, forKey: .secondsToShowQuestion)
        try c.encode(secondsToShowAnswer, forKey: .secondsToShowAnswer)
        try c.encode(questionAction, forKey: .questionAction)
        try c.encode(answerAction, forKey: .answerAction)
        try c.encode(waitForAudio, forKey: .waitForAudio)
        try c.encode(easyDayPercents, forKey: .easyDayPercents)
        try encodeExtraFields(other, to: encoder)
    }
}

enum AutoAdvanceQuestionAction: String, Sendable {
    case showAnswer
    case showReminder
}

enum AutoAdvanceAnswerAction: String, Sendable {
    case buryCard
    case answerAgain
    case answerGood
    case answerHard
    case showReminder
}

enum AutoAdvanceActionResolver {
    static func delayMilliseconds(_ seconds: Double) -> Int? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let milliseconds = seconds * 1_000
        guard milliseconds.isFinite, milliseconds <= Double(Int.max) else { return nil }
        return Int(milliseconds)
    }

    static func shouldAdvance(autoAdvanceEnabled: Bool, isWindowFocused: Bool) -> Bool {
        autoAdvanceEnabled && isWindowFocused
    }

    static func shouldSkipAutoAdvanceForAudio(waitForAudio: Bool, hasUnfinishedPlayback: Bool) -> Bool {
        waitForAudio && hasUnfinishedPlayback
    }

    static func question(_ rawValue: Int) -> AutoAdvanceQuestionAction {
        guard let index = resolvedIndex(rawValue, count: 2) else { return .showAnswer }
        return index == 1 ? .showReminder : .showAnswer
    }

    static func answer(_ rawValue: Int) -> AutoAdvanceAnswerAction {
        guard let index = resolvedIndex(rawValue, count: 5) else { return .buryCard }
        switch index {
        case 1: return .answerAgain
        case 2: return .answerGood
        case 3: return .answerHard
        case 4: return .showReminder
        default: return .buryCard
        }
    }

    private static func resolvedIndex(_ rawValue: Int, count: Int) -> Int? {
        let index = rawValue < 0 ? count + rawValue : rawValue
        return (0..<count).contains(index) ? index : nil
    }
}

enum StudyKeyboardShortcutAction: String, Sendable {
    case showAnswer
    case edit
    case contextMenu
    case replayAudio
    case buryNote
    case buryCard
    case suspendNote
    case suspendCard
    case mark
    case setFlag1
    case setFlag2
    case setFlag3
    case setFlag4
    case setFlag5
    case setFlag6
    case setFlag7
    case deleteNote
    case createCopy
    case setDueDate
    case forgetCard
    case replayOwnVoice
    case recordOwnVoice
    case deckOptions
    case cardInfo
    case previousCardInfo
    case undo
    case pauseAudio
    case seekBackward
    case seekForward
    case toggleAutoAdvance
}

enum StudyToolAction: String, CaseIterable, Identifiable, Sendable {
    case add
    case edit
    case browse
    case cardTemplate
    case customStudy
    case deckStatistics
    case decks
    case deckOptions
    case emptyFilteredDeck
    case filterCram
    case markAndBury
    case markAndSuspend
    case rebuildFilteredDeck
    case studyOptions
    case unburyDeck
    case scratchpad
    case scratchpadSize
    case scrollUp
    case scrollDown
    case userAction1
    case userAction2
    case userAction3
    case userAction4
    case userAction5
    case userAction6
    case userAction7
    case userAction8
    case showAnswer
    case again
    case hard
    case good
    case easy
    case contextMenu
    case replayAudio
    case buryNote
    case buryCard
    case suspendNote
    case suspendCard
    case mark
    case setFlag1
    case setFlag2
    case setFlag3
    case setFlag4
    case setFlag5
    case setFlag6
    case setFlag7
    case deleteNote
    case createCopy
    case setDueDate
    case forgetCard
    case replayOwnVoice
    case recordOwnVoice
    case cardInfo
    case previousCardInfo
    case undo
    case redo
    case configureAutoAdvance
    case pauseAudio
    case seekBackward
    case seekForward
    case toggleAutoAdvance
    case toggleTopBar
    case toggleBottomBar
    case toggleNightMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .add: "Adicionar"
        case .edit: "Editar"
        case .browse: "Abrir navegador"
        case .cardTemplate: "Cartão modelo"
        case .customStudy: "Estudo personalizado"
        case .deckStatistics: "Estatísticas do baralho"
        case .decks: "tab.decks"
        case .emptyFilteredDeck: "Devolver cartões"
        case .filterCram: "Filtro / Cram"
        case .markAndBury: "Marcar e ocultar"
        case .markAndSuspend: "Marcar e suspender"
        case .rebuildFilteredDeck: "Recriar baralho"
        case .studyOptions: "Opções de estudo"
        case .unburyDeck: "Desocultar baralho"
        case .scratchpad: "mobile.scratchpad.name"
        case .scratchpadSize: "Tamanho do bloco de escrita"
        case .scrollUp: "Rolar para cima"
        case .scrollDown: "Rolar para baixo"
        case .userAction1: "Ação do usuário 1"
        case .userAction2: "Ação do usuário 2"
        case .userAction3: "Ação do usuário 3"
        case .userAction4: "Ação do usuário 4"
        case .userAction5: "Ação do usuário 5"
        case .userAction6: "Ação do usuário 6"
        case .userAction7: "Ação do usuário 7"
        case .userAction8: "Ação do usuário 8"
        case .showAnswer: "Mostrar resposta"
        case .again: "De novo"
        case .hard: "Difícil"
        case .good: "Bom"
        case .easy: "Fácil"
        case .contextMenu: "Ferramentas"
        case .replayAudio: "Replay áudio"
        case .buryNote: "Ocultar nota"
        case .buryCard: "Ocultar cartão"
        case .suspendNote: "Suspender nota"
        case .suspendCard: "Suspender cartão"
        case .mark: "Marcar nota"
        case .setFlag1: "Bandeira vermelha"
        case .setFlag2: "Bandeira laranja"
        case .setFlag3: "Bandeira verde"
        case .setFlag4: "Bandeira azul"
        case .setFlag5: "Bandeira rosa"
        case .setFlag6: "Bandeira turquesa"
        case .setFlag7: "Bandeira roxa"
        case .deleteNote: "Apagar nota"
        case .createCopy: "Criar cópia"
        case .setDueDate: "Definir data due"
        case .forgetCard: "Repor cartão"
        case .replayOwnVoice: "Replay voz própria"
        case .recordOwnVoice: "Gravar própria voz"
        case .deckOptions: "deck-options.action"
        case .cardInfo: "Info do cartão"
        case .previousCardInfo: "Info do cartão anterior"
        case .undo: "Desfazer"
        case .redo: "Refazer"
        case .configureAutoAdvance: "Configurar avanço automático"
        case .pauseAudio: "Pausar áudio"
        case .seekBackward: "Áudio −5s"
        case .seekForward: "Áudio +5s"
        case .toggleAutoAdvance: "Avanço automático"
        case .toggleTopBar: "Barra superior"
        case .toggleBottomBar: "Barra inferior"
        case .toggleNightMode: "Modo noturno"
        }
    }

    var systemImage: String {
        switch self {
        case .add: "plus"
        case .edit: "pencil"
        case .browse: "magnifyingglass"
        case .cardTemplate: "doc.text"
        case .customStudy, .filterCram: "sparkles"
        case .deckStatistics: "chart.bar"
        case .decks: "rectangle.stack"
        case .emptyFilteredDeck: "arrow.uturn.backward"
        case .markAndBury, .markAndSuspend: "star"
        case .rebuildFilteredDeck: "arrow.clockwise"
        case .studyOptions, .deckOptions: "gearshape"
        case .unburyDeck: "eye"
        case .scratchpad: "pencil.and.outline"
        case .scratchpadSize: "arrow.up.left.and.arrow.down.right"
        case .scrollUp: "arrow.up"
        case .scrollDown: "arrow.down"
        case .userAction1, .userAction2, .userAction3, .userAction4,
             .userAction5, .userAction6, .userAction7, .userAction8: "bolt"
        case .showAnswer: "eye"
        case .again: "arrow.uturn.backward"
        case .hard: "exclamationmark"
        case .good: "checkmark"
        case .easy: "bolt"
        case .contextMenu: "ellipsis.circle"
        case .replayAudio: "speaker.wave.2.fill"
        case .buryNote: "eye.slash.circle"
        case .buryCard: "eye.slash"
        case .suspendNote: "pause.circle.fill"
        case .suspendCard: "pause.circle"
        case .mark: "star"
        case .setFlag1, .setFlag2, .setFlag3, .setFlag4, .setFlag5, .setFlag6, .setFlag7: "flag.fill"
        case .deleteNote: "trash"
        case .createCopy: "plus.square.on.square"
        case .setDueDate: "calendar"
        case .forgetCard: "arrow.counterclockwise"
        case .replayOwnVoice: "waveform"
        case .recordOwnVoice: "mic.fill"
        case .cardInfo, .previousCardInfo: "info.circle"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .configureAutoAdvance: "gearshape"
        case .pauseAudio: "pause.fill"
        case .seekBackward: "gobackward.5"
        case .seekForward: "goforward.5"
        case .toggleAutoAdvance: "forward.end"
        case .toggleTopBar: "rectangle.topthird.inset.filled"
        case .toggleBottomBar: "rectangle.bottomthird.inset.filled"
        case .toggleNightMode: "moon"
        }
    }

    static let defaultFrequent: [StudyToolAction] = [.edit, .showAnswer, .undo]
}

enum StudyKeyboardShortcutModifiers: String, Sendable {
    case none
    case shift
    case control
    case controlShift
    case controlOption
}

struct StudyKeyboardShortcutBinding: Identifiable, Sendable {
    var key: String
    var modifiers: StudyKeyboardShortcutModifiers
    var action: StudyKeyboardShortcutAction

    var id: String { "\(modifiers.rawValue):\(key)" }
}

enum StudyKeyboardShortcutResolver {
    static let standard: [StudyKeyboardShortcutBinding] = {
        var shortcuts = [
            StudyKeyboardShortcutBinding(key: "e", modifiers: .none, action: .edit),
            StudyKeyboardShortcutBinding(key: "space", modifiers: .none, action: .showAnswer),
            StudyKeyboardShortcutBinding(key: "return", modifiers: .none, action: .showAnswer)
        ]
#if os(macOS)
        shortcuts.append(StudyKeyboardShortcutBinding(key: "enter", modifiers: .none, action: .showAnswer))
#endif
        shortcuts += [
            StudyKeyboardShortcutBinding(key: "m", modifiers: .none, action: .contextMenu),
            StudyKeyboardShortcutBinding(key: "r", modifiers: .none, action: .replayAudio)
        ]
#if os(macOS)
        shortcuts.append(StudyKeyboardShortcutBinding(key: "F5", modifiers: .none, action: .replayAudio))
#endif
        let flags = (1...7).map { flag in
            let actions: [StudyKeyboardShortcutAction] = [
                .setFlag1, .setFlag2, .setFlag3, .setFlag4, .setFlag5, .setFlag6, .setFlag7
            ]
            return StudyKeyboardShortcutBinding(key: String(flag), modifiers: .control, action: actions[flag - 1])
        }
        shortcuts += flags
        shortcuts += [
            StudyKeyboardShortcutBinding(key: "*", modifiers: .none, action: .mark),
            StudyKeyboardShortcutBinding(key: "=", modifiers: .none, action: .buryNote),
            StudyKeyboardShortcutBinding(key: "-", modifiers: .none, action: .buryCard),
            StudyKeyboardShortcutBinding(key: "!", modifiers: .none, action: .suspendNote),
            StudyKeyboardShortcutBinding(key: "@", modifiers: .none, action: .suspendCard),
            StudyKeyboardShortcutBinding(key: "n", modifiers: .controlOption, action: .forgetCard),
            StudyKeyboardShortcutBinding(key: "e", modifiers: .controlOption, action: .createCopy)
        ]
#if os(macOS)
        shortcuts.append(StudyKeyboardShortcutBinding(key: "backspace", modifiers: .control, action: .deleteNote))
#else
        shortcuts.append(StudyKeyboardShortcutBinding(key: "delete", modifiers: .control, action: .deleteNote))
#endif
        shortcuts += [
            StudyKeyboardShortcutBinding(key: "d", modifiers: .controlShift, action: .setDueDate),
            StudyKeyboardShortcutBinding(key: "v", modifiers: .none, action: .replayOwnVoice),
            StudyKeyboardShortcutBinding(key: "v", modifiers: .shift, action: .recordOwnVoice),
            StudyKeyboardShortcutBinding(key: "o", modifiers: .none, action: .deckOptions),
            StudyKeyboardShortcutBinding(key: "i", modifiers: .none, action: .cardInfo),
            StudyKeyboardShortcutBinding(key: "i", modifiers: .controlOption, action: .previousCardInfo),
            StudyKeyboardShortcutBinding(key: "u", modifiers: .none, action: .undo),
            StudyKeyboardShortcutBinding(key: "5", modifiers: .none, action: .pauseAudio),
            StudyKeyboardShortcutBinding(key: "6", modifiers: .none, action: .seekBackward),
            StudyKeyboardShortcutBinding(key: "7", modifiers: .none, action: .seekForward),
            StudyKeyboardShortcutBinding(key: "a", modifiers: .shift, action: .toggleAutoAdvance)
        ]
        return shortcuts
    }()

    static let korean = [
        StudyKeyboardShortcutBinding(key: "ㄷ", modifiers: .none, action: .edit),
        StudyKeyboardShortcutBinding(key: "ㅡ", modifiers: .none, action: .contextMenu),
        StudyKeyboardShortcutBinding(key: "ㄱ", modifiers: .none, action: .replayAudio),
        StudyKeyboardShortcutBinding(key: "ㅜ", modifiers: .controlOption, action: .forgetCard),
        StudyKeyboardShortcutBinding(key: "ㅍ", modifiers: .none, action: .replayOwnVoice),
        StudyKeyboardShortcutBinding(key: "ㅍ", modifiers: .shift, action: .recordOwnVoice),
        StudyKeyboardShortcutBinding(key: "ㅐ", modifiers: .none, action: .deckOptions),
        StudyKeyboardShortcutBinding(key: "ㅑ", modifiers: .none, action: .cardInfo),
        StudyKeyboardShortcutBinding(key: "ㅑ", modifiers: .controlOption, action: .previousCardInfo),
        StudyKeyboardShortcutBinding(key: "ㅕ", modifiers: .none, action: .undo)
    ]
}

struct AnkiRevlog: Identifiable, Hashable, Sendable {
    var id: Int64
    var cid: Int64
    var usn: Int
    var ease: Int
    var ivl: Int
    var lastIvl: Int
    var factor: Int
    var time: Int
    var type: Int
}

struct DeckCounts: Hashable, Sendable {
    var new: Int
    var learn: Int
    var review: Int

    var total: Int { new + learn + review }
}

/// Type-erased Codable helper for Anki's heterogeneous JSON arrays.
struct AnyCodable: Codable, Hashable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let d = try? c.decode([String: AnyCodable].self) { value = d.mapValues(\.value) }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let i as Int64: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let d as [String: Any]: try c.encode(d.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func decodeExtraFields(from decoder: Decoder, excluding knownKeys: Set<String>) throws -> [String: AnyCodable] {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    var fields: [String: AnyCodable] = [:]
    for key in container.allKeys where !knownKeys.contains(key.stringValue) {
        fields[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
    }
    return fields
}

private func encodeExtraFields(_ fields: [String: AnyCodable], to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: AnyCodingKey.self)
    for (key, value) in fields {
        guard let codingKey = AnyCodingKey(stringValue: key) else { continue }
        try container.encode(value, forKey: codingKey)
    }
}

enum Rating: Int, CaseIterable, Sendable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var title: String {
        switch self {
        case .again: "De novo"
        case .hard: "Difícil"
        case .good: "Bom"
        case .easy: "Fácil"
        }
    }
}
