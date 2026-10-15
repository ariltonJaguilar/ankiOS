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
        tags.split(separator: " ").map(String.init).filter { !$0.isEmpty }
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
    var dyn: Int
    var conf: Int64
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AnkiDeck, rhs: AnkiDeck) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.mod == rhs.mod && lhs.dyn == rhs.dyn
    }

    var displayName: String {
        name.split(separator: ":").last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
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

struct AnkiField: Hashable, Codable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case name, ord, sticky, rtl, font, size, description, plainText, collapsed, excludeFromSearch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
    }

    init(name: String, ord: Int, sticky: Bool = false, rtl: Bool = false, font: String = "Arial", size: Int = 20,
         description: String = "", plainText: Bool = false, collapsed: Bool = false, excludeFromSearch: Bool = false) {
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
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
    }
}

struct AnkiTemplate: Hashable, Codable, Sendable {
    var name: String
    var ord: Int
    var qfmt: String
    var afmt: String
    var bqfmt: String
    var bafmt: String
    var did: Int64?
    var bfont: String
    var bsize: Int

    enum CodingKeys: String, CodingKey {
        case name, ord, qfmt, afmt, bqfmt, bafmt, did, bfont, bsize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        ord = try c.decodeIfPresent(Int.self, forKey: .ord) ?? 0
        qfmt = try c.decodeIfPresent(String.self, forKey: .qfmt) ?? ""
        afmt = try c.decodeIfPresent(String.self, forKey: .afmt) ?? ""
        bqfmt = try c.decodeIfPresent(String.self, forKey: .bqfmt) ?? ""
        bafmt = try c.decodeIfPresent(String.self, forKey: .bafmt) ?? ""
        did = try c.decodeIfPresent(Int64.self, forKey: .did)
        bfont = try c.decodeIfPresent(String.self, forKey: .bfont) ?? ""
        bsize = try c.decodeIfPresent(Int.self, forKey: .bsize) ?? 0
    }

    init(name: String, ord: Int, qfmt: String, afmt: String, bqfmt: String = "", bafmt: String = "",
         did: Int64? = nil, bfont: String = "", bsize: Int = 0) {
        self.name = name
        self.ord = ord
        self.qfmt = qfmt
        self.afmt = afmt
        self.bqfmt = bqfmt
        self.bafmt = bafmt
        self.did = did
        self.bfont = bfont
        self.bsize = bsize
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(ord, forKey: .ord)
        try c.encode(qfmt, forKey: .qfmt)
        try c.encode(afmt, forKey: .afmt)
        try c.encode(bqfmt, forKey: .bqfmt)
        try c.encode(bafmt, forKey: .bafmt)
        try c.encodeIfPresent(did, forKey: .did)
        try c.encode(bfont, forKey: .bfont)
        try c.encode(bsize, forKey: .bsize)
    }
}

struct AnkiNotetype: Identifiable, Hashable, Codable, Sendable {
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

    var isCloze: Bool { type == 1 }

    enum CodingKeys: String, CodingKey {
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
        latexPre = try c.decodeIfPresent(String.self, forKey: .latexPre) ?? ""
        latexPost = try c.decodeIfPresent(String.self, forKey: .latexPost) ?? ""
        latexsvg = try c.decodeIfPresent(Bool.self, forKey: .latexsvg) ?? false
        // req is heterogeneous; never fail the whole notetype on it
        req = (try? c.decodeIfPresent([[AnyCodable]].self, forKey: .req)) ?? nil
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        vers = try c.decodeIfPresent([Int].self, forKey: .vers) ?? []
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
        try c.encode(tags, forKey: .tags)
        try c.encode(vers, forKey: .vers)
    }

    init(id: Int64, name: String, type: Int = 0, mod: Int64 = 0, usn: Int = -1, sortf: Int = 0,
         did: Int64? = nil, tmpls: [AnkiTemplate], flds: [AnkiField], css: String = defaultCSS,
         latexPre: String = "", latexPost: String = "", latexsvg: Bool = false,
         req: [[AnyCodable]]? = nil, tags: [String] = [], vers: [Int] = []) {
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

struct AnkiDeckConfig: Identifiable, Hashable, Codable, Sendable {
    var id: Int64
    var name: String
    var mod: Int64
    var usn: Int
    var maxTaken: Int
    var autoplay: Bool
    var timer: Int
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
    var desiredRetention: Double?
    var ignoreRevlogsBeforeDate: String?
    /// When true, new cards are not capped by the remaining review limit.
    var newIgnoreRevLimit: Bool
    /// Monday…Sunday. 1 normal, 0.5 reduced, 0 minimum. Empty means every day is normal.
    var easyDayPercents: [Double]

    struct NewConfig: Hashable, Codable, Sendable {
        var delays: [Double]
        var ints: [Int]
        var initialFactor: Int
        var order: Int
        var perDay: Int
        var bury: Bool

        enum CodingKeys: String, CodingKey {
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
        }

        enum CodingKeys: String, CodingKey {
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
        }
    }

    struct LapseConfig: Hashable, Codable, Sendable {
        var delays: [Double]
        var mult: Double
        var minInt: Int
        var leechFails: Int
        var leechAction: Int

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            delays = try c.decodeIfPresent([Double].self, forKey: .delays) ?? [10]
            mult = try c.decodeIfPresent(Double.self, forKey: .mult) ?? 0
            minInt = try c.decodeIfPresent(Int.self, forKey: .minInt) ?? 1
            leechFails = try c.decodeIfPresent(Int.self, forKey: .leechFails) ?? 8
            leechAction = try c.decodeIfPresent(Int.self, forKey: .leechAction) ?? 0
        }

        enum CodingKeys: String, CodingKey {
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
            ignoreRevlogsBeforeDate: nil,
            newIgnoreRevLimit: false,
            easyDayPercents: []
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, mod, usn, maxTaken, autoplay, timer, replayq, new, rev, lapse, dyn
        case newMix, newPerDayMinimum, interdayLearningMix, reviewOrder, newSortOrder, newGatherPriority
        case buryInterdayLearning, fsrsWeights, desiredRetention, ignoreRevlogsBeforeDate, newIgnoreRevLimit, easyDayPercents
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
        desiredRetention = try c.decodeIfPresent(Double.self, forKey: .desiredRetention)
        ignoreRevlogsBeforeDate = try c.decodeIfPresent(String.self, forKey: .ignoreRevlogsBeforeDate)
        newIgnoreRevLimit = try c.decodeIfPresent(Bool.self, forKey: .newIgnoreRevLimit) ?? false
        easyDayPercents = try c.decodeIfPresent([Double].self, forKey: .easyDayPercents) ?? []
    }

    init(id: Int64, name: String, mod: Int64, usn: Int, maxTaken: Int, autoplay: Bool, timer: Int, replayq: Bool,
         new: NewConfig, rev: RevConfig, lapse: LapseConfig, dyn: Bool, newMix: Int, newPerDayMinimum: Int,
         interdayLearningMix: Int, reviewOrder: Int, newSortOrder: Int, newGatherPriority: Int,
         buryInterdayLearning: Bool, fsrsWeights: [Double]?, desiredRetention: Double?, ignoreRevlogsBeforeDate: String?,
         newIgnoreRevLimit: Bool = false, easyDayPercents: [Double] = []) {
        self.id = id
        self.name = name
        self.mod = mod
        self.usn = usn
        self.maxTaken = maxTaken
        self.autoplay = autoplay
        self.timer = timer
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
        self.desiredRetention = desiredRetention
        self.ignoreRevlogsBeforeDate = ignoreRevlogsBeforeDate
        self.newIgnoreRevLimit = newIgnoreRevLimit
        self.easyDayPercents = easyDayPercents
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
        try c.encodeIfPresent(desiredRetention, forKey: .desiredRetention)
        try c.encodeIfPresent(ignoreRevlogsBeforeDate, forKey: .ignoreRevlogsBeforeDate)
        try c.encode(newIgnoreRevLimit, forKey: .newIgnoreRevLimit)
        try c.encode(easyDayPercents, forKey: .easyDayPercents)
    }
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
