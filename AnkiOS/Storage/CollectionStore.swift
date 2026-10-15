import Foundation
import Combine
import SQLite3
import CommonCrypto

/// App Group shared by the app and the study widget. The collection lives here so a
/// widget can grade a card without launching the app.
enum SharedProfiles {
    static let groupID = "group.com.bigbear.AnkiOS"
    private static let profileKey = "ankios.activeProfile"
    nonisolated(unsafe) private static var didMigrate = false

    static var defaults: UserDefaults {
        UserDefaults(suiteName: groupID) ?? .standard
    }

    static var profilesRoot: URL {
        groupProfiles ?? documentsProfiles
    }

    static func migrateLegacyIfNeeded() {
        guard let group = groupProfiles else { return }
        guard !didMigrate else { return }
        didMigrate = true
        if defaults.string(forKey: profileKey) == nil,
           let legacyName = UserDefaults.standard.string(forKey: profileKey) {
            defaults.set(legacyName, forKey: profileKey)
        }
        let fm = FileManager.default
        let legacy = documentsProfiles
        guard fm.fileExists(atPath: legacy.path) else { return }
        let names = (try? fm.contentsOfDirectory(atPath: legacy.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard !names.isEmpty else { return }
        if !fm.fileExists(atPath: group.path) {
            try? fm.createDirectory(at: group.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy, to: group)
            return
        }
        for name in names {
            let src = legacy.appendingPathComponent(name, isDirectory: true)
            let dst = group.appendingPathComponent(name, isDirectory: true)
            let srcNotes = noteCount(src.appendingPathComponent("collection.anki2"))
            let dstNotes = noteCount(dst.appendingPathComponent("collection.anki2"))
            if !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            } else if srcNotes > 0, dstNotes == 0 {
                let aside = fm.temporaryDirectory.appendingPathComponent("ankios-empty-\(UUID().uuidString)")
                try? fm.moveItem(at: dst, to: aside)
                if (try? fm.moveItem(at: src, to: dst)) == nil {
                    try? fm.moveItem(at: aside, to: dst)
                } else {
                    try? fm.removeItem(at: aside)
                }
            }
        }
    }

    private static var groupProfiles: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    private static var documentsProfiles: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    private static func noteCount(_ database: URL) -> Int {
        guard FileManager.default.fileExists(atPath: database.path) else { return 0 }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            return 0
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM notes", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }
}

/// Why Anki's "you finished this deck for now" screen shows each paragraph.
struct DeckCongrats: Equatable, Sendable {
    var learnCount: Int
    var secsUntilNextLearn: Int
    var reviewRemaining: Bool
    var newRemaining: Bool
    var schedBuried: Bool
    var userBuried: Bool
    var isFiltered: Bool

    var showsLearnMessage: Bool { learnCount > 0 && secsUntilNextLearn < 86_400 }
    var buried: Bool { schedBuried || userBuried }

    /// Anki asks only when both manual (`-3`) and sibling (`-2`) cards are buried.
    var unburyQueues: Set<Int>? {
        if schedBuried && userBuried { return nil }
        if userBuried { return [-3] }
        if schedBuried { return [-2] }
        return []
    }

    static let empty = DeckCongrats(
        learnCount: 0,
        secsUntilNextLearn: 86_400,
        reviewRemaining: false,
        newRemaining: false,
        schedBuried: false,
        userBuried: false,
        isFiltered: false
    )
}

struct CustomStudyAvailability: Equatable, Sendable {
    var newOwn: Int
    var newChildren: Int
    var reviewOwn: Int
    var reviewChildren: Int
    var totalCards: Int
    var tags: [String]

    static let empty = CustomStudyAvailability(
        newOwn: 0, newChildren: 0, reviewOwn: 0, reviewChildren: 0, totalCards: 0, tags: []
    )
}

enum CustomStudyFailure: LocalizedError {
    case renameExisting
    case noCards

    var errorDescription: String? {
        switch self {
        case .renameExisting:
            "Por favor, primeiro renomeie o já existente Baralho de Estudo Personalizado."
        case .noCards:
            "Nenhum cartão atende aos seus critérios."
        }
    }
}

@MainActor
final class CollectionStore: ObservableObject {
    static let shared = CollectionStore()

    @Published var decks: [AnkiDeck] = []
    @Published var notetypes: [AnkiNotetype] = []
    @Published var deckConfigs: [AnkiDeckConfig] = []
    @Published var deckCounts: [Int64: DeckCounts] = [:]
    @Published var isBootstrapping = false
    @Published var lastError: String?
    @Published var conf: [String: Any] = [:]
    @Published var tags: [String: Int] = [:]
    /// Set after the first deck/import lands, until the tutorial is dismissed.
    @Published var shouldShowTutorial = false
    @Published var iCloudSyncing = false
    @Published var iCloudStatus: String?
    /// Called after due counts change so the study widget can refresh.
    var onWidgetRefresh: (() -> Void)?
    /// Bumps when the widget writes the collection, so an open study screen reloads.
    @Published private(set) var widgetRevision = 0
    private var isPublishingWidget = false

    private(set) var db: SQLiteDatabase!
    let mediaStore = MediaStore()
    private let fileManager = FileManager.default

    /// Collection has something worth studying (notes or a non-Default deck).
    var hasStudyContent: Bool {
        if decks.contains(where: { $0.name != "Default" }) { return true }
        let notes = (try? db?.scalarInt("SELECT COUNT(*) FROM notes")) ?? 0
        return notes > 0
    }

    /// Best deck to study first: top-level non-Default with the most due cards.
    var recommendedStudyDeck: AnkiDeck? {
        let roots = decks.filter { $0.parentName == nil && $0.name != "Default" }
        if let best = roots.max(by: { (deckCounts[$0.id]?.total ?? 0) < (deckCounts[$1.id]?.total ?? 0) }),
           (deckCounts[best.id]?.total ?? 0) > 0 {
            return best
        }
        return roots.first ?? decks.first(where: { $0.name != "Default" })
    }

    private static let profileKey = "ankios.activeProfile"
    /// Filtered decks keep study order in `due`. A unix timestamp means the card
    /// was already answered in a session that does not reschedule.
    static let filteredOrderCutoff = 100_000_000

    var activeProfile: String {
        get { SharedProfiles.defaults.string(forKey: Self.profileKey) ?? "User 1" }
        set { SharedProfiles.defaults.set(newValue, forKey: Self.profileKey) }
    }

    var profilesRoot: URL {
        SharedProfiles.migrateLegacyIfNeeded()
        return SharedProfiles.profilesRoot
    }

    var profileDirectory: URL {
        profilesRoot.appendingPathComponent(activeProfile, isDirectory: true)
    }

    var collectionPath: URL {
        // Migrate legacy single-collection layout into the active profile once.
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacy = docs.appendingPathComponent("collection.anki2")
        let modern = profileDirectory.appendingPathComponent("collection.anki2")
        if fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: modern.path) {
            try? fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            try? fileManager.moveItem(at: legacy, to: modern)
            let legacyMedia = docs.appendingPathComponent("collection.media")
            let modernMedia = profileDirectory.appendingPathComponent("collection.media")
            if fileManager.fileExists(atPath: legacyMedia.path), !fileManager.fileExists(atPath: modernMedia.path) {
                try? fileManager.moveItem(at: legacyMedia, to: modernMedia)
            }
        }
        return modern
    }

    var mediaRoot: URL {
        profileDirectory.appendingPathComponent("collection.media", isDirectory: true)
    }

    func listProfiles() -> [String] {
        try? fileManager.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: profilesRoot.path)) ?? []
        var profiles = names.filter { !$0.hasPrefix(".") }.sorted()
        if profiles.isEmpty { profiles = ["User 1"] }
        if !profiles.contains(activeProfile) { profiles.append(activeProfile); profiles.sort() }
        return profiles
    }

    func createProfile(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dir = profilesRoot.appendingPathComponent(trimmed, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func switchProfile(to name: String) async {
        activeProfile = name
        db = nil
        decks = []
        notetypes = []
        deckConfigs = []
        deckCounts = [:]
        conf = [:]
        await bootstrapIfNeeded()
    }

    private init() {}

    /// Uploads or downloads the newer collection and merges media through iCloud Drive.
    func syncWithICloud() async {
        guard !iCloudSyncing else { return }
        iCloudSyncing = true
        defer { iCloudSyncing = false }
        let profiles = profilesRoot
        do {
            if db != nil {
                try db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
                db.closeConnection()
                db = nil
            }
            let summary = try await Task.detached(priority: .userInitiated) {
                try ICloudSync.sync(localProfiles: profiles)
            }.value
            try openOrCreate()
            try reloadMeta()
            try refreshCounts()
            iCloudStatus = summary
        } catch {
            if db == nil {
                try? openOrCreate()
                try? reloadMeta()
                try? refreshCounts()
            }
            lastError = error.localizedDescription
        }
    }

    func bootstrapIfNeeded() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            try openOrCreate()
            try reloadMeta()
            offerTutorialIfNeeded()
            try reloadMeta()
            try refreshCounts()
            try unburySiblingCardsIfNewDay()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Anki auto-unburies buried cards (-2 sibling, -3 manual) at the start of a new day.
    private func unburySiblingCardsIfNewDay() throws {
        let key = "ankios.lastUnburyDay"
        let day = schedDay()
        let last = UserDefaults.standard.integer(forKey: key)
        guard last != day else { return }
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE queue IN (-2, -3)") { stmt in
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        if !ids.isEmpty {
            try restoreCardsToActiveQueue(ids)
        }
        UserDefaults.standard.set(day, forKey: key)
    }

    func offerTutorialIfNeeded() {
        #if !WIDGET_EXTENSION
        shouldShowTutorial = TutorialGate.shouldPresent(store: self)
        #endif
    }

    func notifyDeckContentAdded() {
        offerTutorialIfNeeded()
    }

    func openOrCreate() throws {
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let path = collectionPath.path
        let exists = fileManager.fileExists(atPath: path)
        db = try SQLiteDatabase(path: path)
        if !exists {
            try db.exec(CollectionSchema.createSQL)
            let empty = CollectionSchema.emptyColJSON()
            let now = Int64(Date().timeIntervalSince1970)
            try db.run("""
                INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, ?)
            """) { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, now)
                SQLiteDatabase.bindInt64(stmt, 2, now * 1000)
                SQLiteDatabase.bindInt64(stmt, 3, now * 1000)
                try SQLiteDatabase.bindText(stmt, 4, empty.conf)
                try SQLiteDatabase.bindText(stmt, 5, empty.models)
                try SQLiteDatabase.bindText(stmt, 6, empty.decks)
                try SQLiteDatabase.bindText(stmt, 7, empty.dconf)
                try SQLiteDatabase.bindText(stmt, 8, empty.tags)
            }
        }
    }

    // MARK: - Meta reload

    func reloadMeta() throws {
        guard let decksJSON = try db.scalarText("SELECT decks FROM col"),
              let modelsJSON = try db.scalarText("SELECT models FROM col"),
              let dconfJSON = try db.scalarText("SELECT dconf FROM col"),
              let confJSON = try db.scalarText("SELECT conf FROM col"),
              let tagsJSON = try db.scalarText("SELECT tags FROM col") else {
            throw SQLiteError.exec("Missing col row")
        }

        conf = (try JSONSerialization.jsonObject(with: Data(confJSON.utf8)) as? [String: Any]) ?? [:]
        if conf["ankios.fsrsShipsOff"] == nil {
            conf["scheduler"] = "sm2"
            conf["ankios.fsrsShipsOff"] = true
            try saveConf(conf)
        }
        tags = (try JSONSerialization.jsonObject(with: Data(tagsJSON.utf8)) as? [String: Int]) ?? [:]

        let decksObj = try JSONSerialization.jsonObject(with: Data(decksJSON.utf8)) as? [String: [String: Any]] ?? [:]
        decks = decksObj.values.compactMap(Self.parseDeck).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let modelsData = Data(modelsJSON.utf8)
        let modelsObj = try JSONSerialization.jsonObject(with: modelsData) as? [String: Any] ?? [:]
        var parsedTypes: [AnkiNotetype] = []
        let decoder = JSONDecoder()
        for (key, value) in modelsObj {
            let data = try JSONSerialization.data(withJSONObject: value)
            do {
                parsedTypes.append(try decoder.decode(AnkiNotetype.self, from: data))
            } catch {
                // Last resort: keep a minimal stub so study never blanks on a decode quirk.
                if let dict = value as? [String: Any],
                   let name = dict["name"] as? String,
                   let id = Self.int64(dict["id"]) ?? Int64(key) {
                    let flds = (dict["flds"] as? [[String: Any]] ?? []).enumerated().map { i, f in
                        AnkiField(name: (f["name"] as? String) ?? "Field \(i + 1)", ord: Self.int(f["ord"]) ?? i)
                    }
                    let tmpls = (dict["tmpls"] as? [[String: Any]] ?? []).enumerated().map { i, t in
                        AnkiTemplate(
                            name: (t["name"] as? String) ?? "Card \(i + 1)",
                            ord: Self.int(t["ord"]) ?? i,
                            qfmt: (t["qfmt"] as? String) ?? "",
                            afmt: (t["afmt"] as? String) ?? ""
                        )
                    }
                    parsedTypes.append(AnkiNotetype(
                        id: id, name: name, tmpls: tmpls, flds: flds,
                        css: (dict["css"] as? String) ?? AnkiNotetype.defaultCSS
                    ))
                    lastError = "Notetype “\(name)” loaded with fallback (\(error.localizedDescription))"
                }
            }
        }
        notetypes = parsedTypes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let dconfObj = try JSONSerialization.jsonObject(with: Data(dconfJSON.utf8)) as? [String: Any] ?? [:]
        var configs: [AnkiDeckConfig] = []
        for (_, value) in dconfObj {
            let data = try JSONSerialization.data(withJSONObject: value)
            if let cfg = try? decoder.decode(AnkiDeckConfig.self, from: data) {
                configs.append(cfg)
            }
        }
        if configs.isEmpty { configs = [.default()] }
        deckConfigs = configs.sorted { $0.id < $1.id }
    }

    static func parseDeck(_ dict: [String: Any]) -> AnkiDeck? {
        guard let id = int64(dict["id"]),
              let name = dict["name"] as? String else { return nil }
        return AnkiDeck(
            id: id,
            name: name,
            mod: int64(dict["mod"]) ?? 0,
            usn: int(dict["usn"]) ?? -1,
            collapsed: dict["collapsed"] as? Bool ?? false,
            browserCollapsed: dict["browserCollapsed"] as? Bool ?? false,
            desc: dict["desc"] as? String ?? "",
            dyn: int(dict["dyn"]) ?? 0,
            conf: int64(dict["conf"]) ?? 1,
            extendNew: int(dict["extendNew"]) ?? 0,
            extendRev: int(dict["extendRev"]) ?? 0,
            newToday: (dict["newToday"] as? [Any])?.compactMap { int($0) } ?? [0, 0],
            revToday: (dict["revToday"] as? [Any])?.compactMap { int($0) } ?? [0, 0],
            lrnToday: (dict["lrnToday"] as? [Any])?.compactMap { int($0) } ?? [0, 0],
            timeToday: (dict["timeToday"] as? [Any])?.compactMap { int($0) } ?? [0, 0],
            searchTerms: (dict["terms"] as? [[Any]])?.first.flatMap { $0.first as? String },
            termLimit: (dict["terms"] as? [[Any]])?.first.flatMap { CollectionStore.int($0.dropFirst().first) },
            resched: dict["resched"] as? Bool,
            previewDelay: int(dict["previewDelay"]),
            searchOrder: dict["ankiosSearchOrder"] as? String,
            includeTags: dict["ankiosIncludeTags"] as? String,
            excludeTags: dict["ankiosExcludeTags"] as? String,
            previewAgain: int(dict["previewAgain"]),
            previewHard: int(dict["previewHard"]),
            previewGood: int(dict["previewGood"]),
            searchTerms2: (dict["terms"] as? [[Any]])?.dropFirst().first.flatMap { $0.first as? String },
            termLimit2: (dict["terms"] as? [[Any]])?.dropFirst().first.flatMap { CollectionStore.int($0.dropFirst().first) },
            searchOrder2: dict["ankiosSearchOrder2"] as? String
        )
    }

    // MARK: - Counts

    func refreshCounts() throws {
        let day = schedDay()
        let now = Int(Date().timeIntervalSince1970)
        let collapse = conf["collapseTime"] as? Int ?? 1200
        var result: [Int64: DeckCounts] = [:]
        for deck in decks {
            let ids = deckTreeIDs(including: deck.id)
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let cfg = config(for: deck)
            let filtered = deck.isFiltered
            let limits = filtered
                ? (new: Int.max, rev: Int.max)
                : remainingDailyLimits(for: deck.id, newLimit: cfg.new.perDay, revLimit: cfg.rev.perDay)
            let queue3Cutoff = filtered ? Self.filteredOrderCutoff : day
            let queue3Op = filtered ? "<" : "<="
            let reviewCutoff = filtered ? Self.filteredOrderCutoff : day
            let reviewOp = filtered ? "<" : "<="
            let newCount = try db.scalarInt("""
                SELECT COUNT(*) FROM cards WHERE did IN (\(placeholders)) AND queue = 0
            """) { stmt in
                for (i, id) in ids.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
                }
            }
            let learnCount = try db.scalarInt("""
                SELECT COUNT(*) FROM cards WHERE did IN (\(placeholders))
                AND ((queue IN (1, 4) AND due <= ?) OR (queue = 3 AND due \(queue3Op) ?))
            """) { stmt in
                for (i, id) in ids.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
                }
                SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1), now + collapse)
                SQLiteDatabase.bindInt(stmt, Int32(ids.count + 2), queue3Cutoff)
            }
            let reviewCount = try db.scalarInt("""
                SELECT COUNT(*) FROM cards WHERE did IN (\(placeholders)) AND queue = 2 AND due \(reviewOp) ?
            """) { stmt in
                for (i, id) in ids.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
                }
                SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1), reviewCutoff)
            }
            result[deck.id] = DeckCounts(
                new: min(newCount, limits.new),
                learn: learnCount,
                review: min(reviewCount, limits.rev)
            )
        }
        deckCounts = result
        guard !isPublishingWidget else { return }
        isPublishingWidget = true
        defer { isPublishingWidget = false }
        onWidgetRefresh?()
    }

    func deckTreeIDs(including rootID: Int64) -> [Int64] {
        guard let root = decks.first(where: { $0.id == rootID }) else { return [rootID] }
        let prefix = root.name + "::"
        let children = decks.filter { $0.id == rootID || $0.name == root.name || $0.name.hasPrefix(prefix) }
        return children.map(\.id)
    }

    func schedDay() -> Int {
        let rollover = conf["rollday"] as? Int ?? 4
        let offsetHours = rollover
        let seconds = Date().timeIntervalSince1970 - Double(offsetHours * 3600)
        let crt = (try? db.scalarInt64("SELECT crt FROM col")) ?? Int64(Date().timeIntervalSince1970)
        return Int((seconds - Double(crt)) / 86400.0)
    }

    /// Start of the window Anki uses for `added:N` and `rated:N`. Day 1 is today.
    func searchDayStart(days: Int) -> Int64 {
        let n = max(days, 1)
        return schedDayStartTimestamp() - Int64(n - 1) * 86_400
    }

    /// Unix timestamp (seconds) when the current scheduling day started (rollday-aware).
    func schedDayStartTimestamp() -> Int64 {
        let rollover = conf["rollday"] as? Int ?? 4
        let crt = (try? db.scalarInt64("SELECT crt FROM col")) ?? Int64(Date().timeIntervalSince1970)
        let day = schedDay()
        return crt + Int64(day * 86400) + Int64(rollover * 3600)
    }

    func collectionCreation() -> Int64 {
        (try? db.scalarInt64("SELECT crt FROM col")) ?? Int64(Date().timeIntervalSince1970)
    }

    // MARK: - Cards / Notes

    func fetchCard(id: Int64) throws -> AnkiCard? {
        var card: AnkiCard?
        try db.query("SELECT * FROM cards WHERE id = ?", bind: { SQLiteDatabase.bindInt64($0, 1, id) }) { stmt in
            card = Self.mapCard(stmt)
        }
        return card
    }

    func fetchNote(id: Int64) throws -> AnkiNote? {
        var note: AnkiNote?
        try db.query("SELECT * FROM notes WHERE id = ?", bind: { SQLiteDatabase.bindInt64($0, 1, id) }) { stmt in
            note = Self.mapNote(stmt)
        }
        return note
    }

    func notetype(id: Int64) -> AnkiNotetype? {
        notetypes.first { $0.id == id }
    }

    func deck(id: Int64) -> AnkiDeck? {
        decks.first { $0.id == id }
    }

    func config(for deck: AnkiDeck) -> AnkiDeckConfig {
        deckConfigs.first { $0.id == deck.conf } ?? .default()
    }

    /// Remaining new/review slots for today on the selected deck (Anki newToday/revToday).
    func remainingDailyLimits(for deckID: Int64, newLimit: Int, revLimit: Int) -> (new: Int, rev: Int) {
        try? clearStaleDailyExtensions()
        guard let deck = decks.first(where: { $0.id == deckID }) else {
            return (max(0, newLimit), max(0, revLimit))
        }
        let day = schedDay()
        let newUsed = todayCounter(deck.newToday, day: day)
        let revUsed = todayCounter(deck.revToday, day: day)
        return (
            max(0, newLimit + deck.extendNew - newUsed),
            max(0, revLimit + deck.extendRev - revUsed)
        )
    }

    /// Anki clears custom-study extendNew/extendRev when the scheduling day rolls over.
    /// We stamp `newToday[0]` / `revToday[0]` to today when extending so stale days are detectable.
    private func clearStaleDailyExtensions() throws {
        let day = schedDay()
        var next = decks
        var changed = false
        for i in next.indices {
            guard next[i].extendNew != 0 || next[i].extendRev != 0 else { continue }
            let stamp = max(next[i].newToday.first ?? 0, next[i].revToday.first ?? 0)
            if stamp != 0 && stamp != day {
                next[i].extendNew = 0
                next[i].extendRev = 0
                changed = true
            }
        }
        if changed { try saveDecks(next) }
    }

    /// Stamp today's day onto deck counters so extendNew/extendRev expire at rollover.
    func stampExtendDay(deckID: Int64) throws {
        let day = schedDay()
        var next = decks
        guard let idx = next.firstIndex(where: { $0.id == deckID }) else { return }
        if next[idx].newToday.count < 2 || next[idx].newToday[0] != day {
            next[idx].newToday = [day, todayCounter(next[idx].newToday, day: day)]
        }
        if next[idx].revToday.count < 2 || next[idx].revToday[0] != day {
            next[idx].revToday = [day, todayCounter(next[idx].revToday, day: day)]
        }
        try saveDecks(next)
    }

    private static func parseProp(_ token: String, key: String) -> (op: String, value: Int)? {
        let prefix = "prop:\(key)"
        guard token.hasPrefix(prefix) else { return nil }
        let rest = String(token.dropFirst(prefix.count))
        for op in ["<=", ">=", "==", "=", "<", ">"] {
            if rest.hasPrefix(op), let n = Int(rest.dropFirst(op.count)) {
                let sqlOp = op == "==" || op == "=" ? "=" : op
                return (sqlOp, n)
            }
        }
        return nil
    }

    /// `prop:ease>2.5` compares the stored factor (2500), the same scale Anki shows as 250%.
    private static func parsePropScaled(_ token: String, key: String, scale: Double) -> (op: String, value: Int)? {
        let prefix = "prop:\(key)"
        guard token.hasPrefix(prefix) else { return nil }
        let rest = String(token.dropFirst(prefix.count))
        for op in ["<=", ">=", "==", "=", "<", ">"] {
            if rest.hasPrefix(op), let n = Double(rest.dropFirst(op.count)) {
                let sqlOp = op == "==" || op == "=" ? "=" : op
                return (sqlOp, Int((n * scale).rounded()))
            }
        }
        return nil
    }

    private func todayCounter(_ pair: [Int], day: Int) -> Int {
        guard pair.count >= 2 else { return 0 }
        return pair[0] == day ? pair[1] : 0
    }

    /// Increment newToday / revToday / lrnToday on the card's deck after answering.
    func recordTodayStudy(deckID: Int64, wasNew: Bool, wasReview: Bool, wasLearn: Bool, timeMS: Int) throws {
        try mutateTodayCounters(deckID: deckID, wasNew: wasNew, wasReview: wasReview, wasLearn: wasLearn, timeMS: timeMS, delta: 1)
    }

    func recordTodayStudyUndo(deckID: Int64, wasNew: Bool, wasReview: Bool, wasLearn: Bool, timeMS: Int) throws {
        try mutateTodayCounters(deckID: deckID, wasNew: wasNew, wasReview: wasReview, wasLearn: wasLearn, timeMS: timeMS, delta: -1)
    }

    private func mutateTodayCounters(deckID: Int64, wasNew: Bool, wasReview: Bool, wasLearn: Bool, timeMS: Int, delta: Int) throws {
        let day = schedDay()
        var next = decks
        guard let idx = next.firstIndex(where: { $0.id == deckID }) else { return }
        func bump(_ pair: inout [Int]) {
            if pair.count < 2 || pair[0] != day {
                pair = [day, max(0, delta)]
            } else {
                pair[1] = max(0, pair[1] + delta)
            }
        }
        if wasNew { bump(&next[idx].newToday) }
        if wasReview { bump(&next[idx].revToday) }
        if wasLearn { bump(&next[idx].lrnToday) }
        if next[idx].timeToday.count < 2 || next[idx].timeToday[0] != day {
            next[idx].timeToday = [day, max(0, delta > 0 ? timeMS : 0)]
        } else {
            next[idx].timeToday[1] = max(0, next[idx].timeToday[1] + (delta > 0 ? timeMS : -timeMS))
        }
        next[idx].mod = Int64(Date().timeIntervalSince1970)
        try saveDecks(next)
    }

    func dueCards(for deckID: Int64, newLimit: Int, revLimit: Int) throws -> [AnkiCard] {
        let ids = deckTreeIDs(including: deckID)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let day = schedDay()
        let now = Int(Date().timeIntervalSince1970)
        let collapse = conf["collapseTime"] as? Int ?? 1200
        let isFiltered = decks.first(where: { $0.id == deckID })?.isFiltered == true
        // Filtered decks ignore daily new/rev caps (Anki custom study / dyn).
        let limits = isFiltered
            ? (new: 99_999, rev: 99_999)
            : remainingDailyLimits(for: deckID, newLimit: newLimit, revLimit: revLimit)
        let effectiveNew = limits.new
        let effectiveRev = limits.rev

        // Intraday learning: cards already due come first. Cards only inside the
        // learn-ahead window wait until new and review cards are finished, so
        // Again does not repeat the same card while others remain.
        var learnDue: [AnkiCard] = []
        var learnEarly: [AnkiCard] = []
        try db.query("""
            SELECT * FROM cards WHERE did IN (\(placeholders)) AND queue IN (1, 4) AND due <= ?
            ORDER BY CASE WHEN reps = 0 THEN 1 ELSE 0 END, due ASC, id ASC
        """) { stmt in
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
            SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1), now + collapse)
        } map: { stmt in
            let card = Self.mapCard(stmt)
            if card.due <= now {
                learnDue.append(card)
            } else {
                learnEarly.append(card)
            }
        }

        var dayLearn: [AnkiCard] = []
        let queue3Op = isFiltered ? "<" : "<="
        let queue3Cutoff = isFiltered ? Self.filteredOrderCutoff : day
        try db.query("""
            SELECT * FROM cards WHERE did IN (\(placeholders)) AND queue = 3 AND due \(queue3Op) ?
            ORDER BY due ASC, id ASC
        """) { stmt in
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
            SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1), queue3Cutoff)
        } map: { stmt in
            dayLearn.append(Self.mapCard(stmt))
        }

        let deck = decks.first(where: { $0.id == deckID })
        let cfg = deck.map { config(for: $0) }

        var reviews: [AnkiCard] = []
        if effectiveRev > 0 {
            let reviewOrderSQL: String
            if isFiltered {
                reviewOrderSQL = "ORDER BY due ASC, id ASC"
            } else {
                switch cfg?.reviewOrder ?? 0 {
                case 1: reviewOrderSQL = "ORDER BY RANDOM()"
                case 2: reviewOrderSQL = "ORDER BY ivl ASC, due ASC"
                case 3: reviewOrderSQL = "ORDER BY ivl DESC, due ASC"
                case 4: reviewOrderSQL = "ORDER BY factor ASC, due ASC"
                case 5: reviewOrderSQL = "ORDER BY factor DESC, due ASC"
                default: reviewOrderSQL = "ORDER BY due ASC"
                }
            }
            let reviewOp = isFiltered ? "<" : "<="
            let reviewCutoff = isFiltered ? Self.filteredOrderCutoff : day
            try db.query("""
                SELECT * FROM cards WHERE did IN (\(placeholders)) AND queue = 2 AND due \(reviewOp) ?
                \(reviewOrderSQL) LIMIT ?
            """) { stmt in
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1), reviewCutoff)
                SQLiteDatabase.bindInt(stmt, Int32(ids.count + 2), effectiveRev)
            } map: { stmt in
                reviews.append(Self.mapCard(stmt))
            }
        }

        let dayLearnFirst = conf["dayLearnFirst"] as? Bool ?? false
        // Prefer deck newMix (Anki display order); fall back to collection newSpread.
        let newSpread = cfg?.newMix ?? (conf["newSpread"] as? Int ?? 0)
        let interdayMix = cfg?.interdayLearningMix ?? 0
        let minNew = cfg?.newPerDayMinimum ?? 0

        // v3: new cards share the review limit with interday learning + reviews,
        // unless the preset says new cards ignore that limit.
        var newFetch = effectiveNew
        if !isFiltered && cfg?.newIgnoreRevLimit != true {
            let revUsed = dayLearn.count + reviews.count
            let headroom = max(0, effectiveRev - revUsed)
            newFetch = min(effectiveNew, headroom)
            if minNew > 0 {
                newFetch = max(newFetch, min(minNew, effectiveNew))
            }
        }

        var news: [AnkiCard] = []
        if newFetch > 0 {
            let newOrder = cfg?.new.order ?? 0
            let gather = cfg?.newGatherPriority ?? 0
            // Anki NewCardGatherPriority + new.order (random within deck).
            // Filtered decks already stored the chosen order in `due`.
            let orderSQL: String
            if isFiltered {
                orderSQL = "ORDER BY due ASC, id ASC"
            } else {
                switch gather {
                case 3: orderSQL = "ORDER BY due DESC"
                case 4, 5: orderSQL = "ORDER BY RANDOM()"
                case 1: orderSQL = "ORDER BY did DESC, due ASC"
                default:
                    orderSQL = newOrder == 1 ? "ORDER BY RANDOM()" : "ORDER BY due ASC"
                }
            }
            try db.query("""
                SELECT * FROM cards WHERE did IN (\(placeholders)) AND queue = 0
                \(orderSQL) LIMIT ?
            """) { stmt in
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1), newFetch)
            } map: { stmt in
                news.append(Self.mapCard(stmt))
            }
        }

        func mergeNewWithReviews(_ reviewCards: [AnkiCard]) -> [AnkiCard] {
            switch newSpread {
            case 2: return news + reviewCards
            case 1: return reviewCards + news
            default: return interleave(reviewCards, news)
            }
        }

        if dayLearnFirst {
            return dayLearn + learnDue + mergeNewWithReviews(reviews) + learnEarly
        }

        let reviewBlock: [AnkiCard]
        switch interdayMix {
        case 1:
            reviewBlock = reviews + dayLearn
        case 2:
            reviewBlock = dayLearn + reviews
        default:
            reviewBlock = interleave(reviews, dayLearn)
        }
        return learnDue + mergeNewWithReviews(reviewBlock) + learnEarly
    }

    /// Persist Anki `curDeck` so Add / `deck:current` follow the last studied deck.
    func setCurrentDeck(_ deckID: Int64) {
        var next = conf
        next["curDeck"] = deckID
        try? saveConf(next)
    }

    func currentDeckID() -> Int64? {
        if let n = conf["curDeck"] as? Int64 { return n }
        if let n = conf["curDeck"] as? Int { return Int64(n) }
        if let n = conf["curDeck"] as? NSNumber { return n.int64Value }
        return nil
    }

    /// Anki's Intersperser: spread the two queues evenly, taking from the longer one first.
    private func interleave(_ reviews: [AnkiCard], _ others: [AnkiCard]) -> [AnkiCard] {
        var result: [AnkiCard] = []
        result.reserveCapacity(reviews.count + others.count)
        let oneLen = reviews.count
        let twoLen = others.count
        let ratio = Float(oneLen + 1) / Float(twoLen + 1)
        var i = 0
        var j = 0
        while i < oneLen || j < twoLen {
            if i < oneLen, j < twoLen {
                let relative = Float(j + 1) * ratio
                if relative < Float(i + 1) {
                    result.append(others[j])
                    j += 1
                } else {
                    result.append(reviews[i])
                    i += 1
                }
            } else if i < oneLen {
                result.append(reviews[i])
                i += 1
            } else {
                result.append(others[j])
                j += 1
            }
        }
        return result
    }

    /// Anki `congrats_info`: which paragraphs the finished-deck screen shows.
    /// Cards in this deck tree that have already been seen. Used by the widget's "Estudar de novo".
    func seenCardCount(in deckID: Int64) throws -> Int {
        let ids = deckTreeIDs(including: deckID)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try db.scalarInt("""
            SELECT COUNT(*) FROM cards WHERE did IN (\(placeholders)) AND type != 0 AND queue != -1
        """) { stmt in
            for (i, id) in ids.enumerated() {
                SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
            }
        }
    }

    /// Reload after the widget wrote the shared collection. Does not bring the app forward.
    func reloadAfterExternalEdit() async {
        guard fileManager.fileExists(atPath: collectionPath.path) else { return }
        if db == nil {
            await bootstrapIfNeeded()
        } else {
            try? reloadMeta()
            try? refreshCounts()
        }
        widgetRevision += 1
    }

    func congratsState(for deckID: Int64) throws -> DeckCongrats {
        let ids = deckTreeIDs(including: deckID)
        guard !ids.isEmpty else { return .empty }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        func bindIDs(_ stmt: OpaquePointer) {
            for (i, id) in ids.enumerated() {
                SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
            }
        }
        func count(_ sql: String, extra: ((OpaquePointer) -> Void)? = nil) throws -> Int {
            try db.scalarInt("SELECT COUNT(*) FROM cards WHERE did IN (\(placeholders)) AND \(sql)") { stmt in
                bindIDs(stmt)
                extra?(stmt)
            }
        }
        let day = schedDay()
        let newCount = try count("queue = 0")
        let reviewCount = try count("queue IN (2, 3) AND due <= ?") { stmt in
            SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1), day)
        }
        let schedBuried = try count("queue = -2")
        let userBuried = try count("queue = -3")
        let learnCount = try count("queue = 1")
        var nextDue = 0
        try db.query("SELECT MIN(due) FROM cards WHERE did IN (\(placeholders)) AND queue = 1", bind: { bindIDs($0) }) { stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                nextDue = Int(sqlite3_column_int(stmt, 0))
            }
        }
        let now = Int(Date().timeIntervalSince1970)
        let collapse = conf["collapseTime"] as? Int ?? 1200
        let secsUntilNextLearn = nextDue == 0 ? 86_400 : max(60, nextDue - collapse - now)
        return DeckCongrats(
            learnCount: learnCount,
            secsUntilNextLearn: secsUntilNextLearn,
            reviewRemaining: reviewCount > 0,
            newRemaining: newCount > 0,
            schedBuried: schedBuried > 0,
            userBuried: userBuried > 0,
            isFiltered: decks.first { $0.id == deckID }?.isFiltered == true
        )
    }

    /// Counts shown in Anki's Custom Study dialog (own cards vs subdecks).
    func customStudyAvailability(for deckID: Int64) throws -> CustomStudyAvailability {
        let ids = deckTreeIDs(including: deckID)
        guard !ids.isEmpty else { return .empty }
        let day = schedDay()
        func count(ownOnly: Bool, sql: String, extra: ((OpaquePointer) -> Void)? = nil) throws -> Int {
            let scope = ownOnly ? "did = ?" : "did IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            return try db.scalarInt("SELECT COUNT(*) FROM cards WHERE \(scope) AND \(sql)") { stmt in
                if ownOnly {
                    SQLiteDatabase.bindInt64(stmt, 1, deckID)
                    extra?(stmt)
                } else {
                    for (i, id) in ids.enumerated() {
                        SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
                    }
                    extra?(stmt)
                }
            }
        }
        let reviewSQL = "queue = 2 AND due <= ?"
        let bindDay: (OpaquePointer) -> Void = { SQLiteDatabase.bindInt($0, 2, day) }
        let bindDayTree: (OpaquePointer) -> Void = { SQLiteDatabase.bindInt($0, Int32(ids.count + 1), day) }
        let newOwn = try count(ownOnly: true, sql: "queue = 0")
        let newTree = try count(ownOnly: false, sql: "queue = 0")
        let revOwn = try count(ownOnly: true, sql: reviewSQL, extra: bindDay)
        let revTree = try count(ownOnly: false, sql: reviewSQL, extra: bindDayTree)
        let total = try count(ownOnly: false, sql: "1=1")
        var tags = Set<String>()
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        try db.query("""
            SELECT n.tags FROM notes n
            JOIN cards c ON c.nid = n.id
            WHERE c.did IN (\(ph))
        """, bind: { stmt in
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        }) { stmt in
            let raw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            for tag in raw.split(separator: " ") where !tag.isEmpty {
                tags.insert(String(tag))
            }
        }
        return CustomStudyAvailability(
            newOwn: newOwn,
            newChildren: max(0, newTree - newOwn),
            reviewOwn: revOwn,
            reviewChildren: max(0, revTree - revOwn),
            totalCards: total,
            tags: tags.sorted()
        )
    }

    /// Anki custom study: extend today's new or review limit. `delta` may be negative.
    /// Parents are included, matching Apply All Parent Limits.
    func extendTodayLimit(deckID: Int64, newDelta: Int, reviewDelta: Int) throws {
        guard let deck = decks.first(where: { $0.id == deckID }) else { return }
        let day = schedDay()
        var next = decks
        var names = [deck.name]
        if conf["applyAllParentLimits"] as? Bool ?? true {
            var parts = deck.pathComponents
            while parts.count > 1 {
                parts.removeLast()
                names.append(parts.joined(separator: "::"))
            }
        }
        var changed = false
        for name in names {
            guard let idx = next.firstIndex(where: { $0.name == name && !$0.isFiltered }) else { continue }
            next[idx].extendNew += newDelta
            next[idx].extendRev += reviewDelta
            next[idx].mod = Int64(Date().timeIntervalSince1970)
            if next[idx].newToday.count < 2 || next[idx].newToday[0] != day {
                next[idx].newToday = [day, todayCounter(next[idx].newToday, day: day)]
            }
            if next[idx].revToday.count < 2 || next[idx].revToday[0] != day {
                next[idx].revToday = [day, todayCounter(next[idx].revToday, day: day)]
            }
            changed = true
        }
        if changed { try saveDecks(next) }
    }

    /// Reuse or create Anki's single "Sessão de Estudo Personalizado" filtered deck.
    /// Cards are gathered only after any previous session is restored, and an empty
    /// search puts that session back (Anki rolls the rebuild back).
    @MainActor
    func buildCustomStudySession(
        query: String,
        limit: Int,
        reschedule: Bool,
        order: String,
        includeTags: String? = nil,
        excludeTags: String? = nil
    ) throws -> AnkiDeck {
        let sessionName = "Sessão de Estudo Personalizado"
        if let existing = decks.first(where: { $0.name == sessionName }), !existing.isFiltered {
            throw CustomStudyFailure.renameExisting
        }

        let previous = decks.first { $0.name == sessionName && $0.isFiltered }
        var snapshot: [AnkiCard] = []
        if let previous {
            var ids: [Int64] = []
            try db.query("SELECT id FROM cards WHERE did = ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, previous.id)
            }) { stmt in
                ids.append(sqlite3_column_int64(stmt, 0))
            }
            snapshot = try ids.compactMap { try fetchCard(id: $0) }
            try FilteredDeckSupport.empty(previous, store: self)
        }

        let fetchCap = max(limit, 500_000)
        var rows = try self.search(query: FilteredDeckSupport.gatherSearch(query), limit: fetchCap)
        rows = FilteredDeckSupport.applyTagFilter(rows, include: includeTags, exclude: excludeTags)
        FilteredDeckSupport.sortForGather(
            &rows,
            order: order,
            today: schedDay(),
            now: Int(Date().timeIntervalSince1970),
            shuffle: order == "random"
        )
        let chosen = Array(rows.prefix(max(limit, 0)))
        guard !chosen.isEmpty else {
            for card in snapshot {
                try updateCard(card)
            }
            try refreshCounts()
            throw CustomStudyFailure.noCards
        }

        var working = decks
        let deckID: Int64
        if let idx = working.firstIndex(where: { $0.name == sessionName && $0.isFiltered }) {
            deckID = working[idx].id
            working[idx].searchTerms = query
            working[idx].termLimit = limit
            working[idx].resched = reschedule
            working[idx].searchOrder = order
            working[idx].includeTags = includeTags
            working[idx].excludeTags = excludeTags
            working[idx].mod = Int64(Date().timeIntervalSince1970)
        } else {
            deckID = timestampID()
            var created = AnkiDeck(
                id: deckID,
                name: sessionName,
                mod: Int64(Date().timeIntervalSince1970),
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
                searchTerms: query,
                termLimit: limit,
                resched: reschedule,
                previewDelay: 10,
                searchOrder: order
            )
            created.includeTags = includeTags
            created.excludeTags = excludeTags
            working.append(created)
        }
        try saveDecks(working)

        try FilteredDeckSupport.install(
            cardIDs: chosen.map(\.card.id),
            deckID: deckID,
            reschedule: reschedule,
            store: self
        )
        try refreshCounts()
        setCurrentDeck(deckID)
        return deck(id: deckID) ?? working.first { $0.id == deckID }!
    }

    func findReplaceFields(noteIDs: [Int64], find: String, replace: String) throws -> Int {
        guard !find.isEmpty else { return 0 }
        var changed = 0
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            var fields = note.fields
            var any = false
            for i in fields.indices {
                if fields[i].contains(find) {
                    fields[i] = fields[i].replacingOccurrences(of: find, with: replace)
                    any = true
                }
            }
            if any {
                try updateNote(note, fields: fields, tags: note.tagList.joined(separator: " "))
                changed += 1
            }
        }
        return changed
    }

    func updateCard(_ card: AnkiCard) throws {
        try db.run("""
            UPDATE cards SET nid=?, did=?, ord=?, mod=?, usn=?, type=?, queue=?, due=?, ivl=?, factor=?,
            reps=?, lapses=?, left=?, odue=?, odid=?, flags=?, data=? WHERE id=?
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, card.nid)
            SQLiteDatabase.bindInt64(stmt, 2, card.did)
            SQLiteDatabase.bindInt(stmt, 3, card.ord)
            SQLiteDatabase.bindInt64(stmt, 4, card.mod)
            SQLiteDatabase.bindInt(stmt, 5, card.usn)
            SQLiteDatabase.bindInt(stmt, 6, card.type)
            SQLiteDatabase.bindInt(stmt, 7, card.queue)
            SQLiteDatabase.bindInt(stmt, 8, card.due)
            SQLiteDatabase.bindInt(stmt, 9, card.ivl)
            SQLiteDatabase.bindInt(stmt, 10, card.factor)
            SQLiteDatabase.bindInt(stmt, 11, card.reps)
            SQLiteDatabase.bindInt(stmt, 12, card.lapses)
            SQLiteDatabase.bindInt(stmt, 13, card.left)
            SQLiteDatabase.bindInt(stmt, 14, card.odue)
            SQLiteDatabase.bindInt64(stmt, 15, card.odid)
            SQLiteDatabase.bindInt(stmt, 16, card.flags)
            try SQLiteDatabase.bindText(stmt, 17, card.data)
            SQLiteDatabase.bindInt64(stmt, 18, card.id)
        }
        try touchCol()
    }

    func insertRevlog(_ r: AnkiRevlog) throws {
        try db.run("""
            INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, r.id)
            SQLiteDatabase.bindInt64(stmt, 2, r.cid)
            SQLiteDatabase.bindInt(stmt, 3, r.usn)
            SQLiteDatabase.bindInt(stmt, 4, r.ease)
            SQLiteDatabase.bindInt(stmt, 5, r.ivl)
            SQLiteDatabase.bindInt(stmt, 6, r.lastIvl)
            SQLiteDatabase.bindInt(stmt, 7, r.factor)
            SQLiteDatabase.bindInt(stmt, 8, r.time)
            SQLiteDatabase.bindInt(stmt, 9, r.type)
        }
    }

    func touchCol() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run("UPDATE col SET mod = ?", bind: { SQLiteDatabase.bindInt64($0, 1, now) })
    }

    // MARK: - Deck meta persistence

    func saveDecks(_ decks: [AnkiDeck]) throws {
        var dict: [String: Any] = [:]
        for d in decks {
            dict[String(d.id)] = deckToDict(d)
        }
        let json = CollectionSchema.encodeJSON(dict)
        try db.run("UPDATE col SET decks = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
        try touchCol()
        try reloadMeta()
        try refreshCounts()
    }

    func saveNotetypes(_ types: [AnkiNotetype]) throws {
        var dict: [String: Any] = [:]
        let encoder = JSONEncoder()
        for t in types {
            let data = try encoder.encode(t)
            let obj = try JSONSerialization.jsonObject(with: data)
            dict[String(t.id)] = obj
        }
        let json = CollectionSchema.encodeJSON(dict)
        try db.run("UPDATE col SET models = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
        try touchCol()
        try reloadMeta()
    }

    func saveDeckConfigs(_ configs: [AnkiDeckConfig]) throws {
        var dict: [String: Any] = [:]
        let encoder = JSONEncoder()
        for c in configs {
            let data = try encoder.encode(c)
            let obj = try JSONSerialization.jsonObject(with: data)
            dict[String(c.id)] = obj
        }
        let json = CollectionSchema.encodeJSON(dict)
        try db.run("UPDATE col SET dconf = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
        try touchCol()
        try reloadMeta()
        // Presets are shared. Recompute every deck now — Anki's deck list updates
        // as soon as the daily limits change, not on the next launch.
        try refreshCounts()
    }

    func saveConf(_ conf: [String: Any]) throws {
        let json = CollectionSchema.encodeJSON(conf)
        try db.run("UPDATE col SET conf = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
        self.conf = conf
        try touchCol()
    }

    /// Painel: named searches persisted in col conf (`savedSearches` as [[name, query]]).
    var savedSearches: [(name: String, query: String)] {
        guard let raw = conf["savedSearches"] as? [[Any]] else { return [] }
        return raw.compactMap { pair in
            guard pair.count >= 2,
                  let name = pair[0] as? String,
                  let query = pair[1] as? String,
                  !name.isEmpty else { return nil }
            return (name, query)
        }
    }

    func setSavedSearches(_ items: [(name: String, query: String)]) throws {
        var c = conf
        c["savedSearches"] = items.map { [$0.name, $0.query] as [Any] }
        try saveConf(c)
    }

    func addSavedSearch(name: String, query: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedQuery.isEmpty else { return }
        var items = savedSearches.filter { $0.name != trimmedName }
        items.append((trimmedName, trimmedQuery))
        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try setSavedSearches(items)
    }

    func removeSavedSearch(named name: String) throws {
        try setSavedSearches(savedSearches.filter { $0.name != name })
    }

    func deckToDict(_ d: AnkiDeck) -> [String: Any] {
        var dict: [String: Any] = [
            "id": d.id,
            "name": d.name,
            "mod": d.mod,
            "usn": d.usn,
            "collapsed": d.collapsed,
            "browserCollapsed": d.browserCollapsed,
            "desc": d.desc,
            "dyn": d.dyn,
            "conf": d.conf,
            "extendNew": d.extendNew,
            "extendRev": d.extendRev,
            "newToday": d.newToday,
            "revToday": d.revToday,
            "lrnToday": d.lrnToday,
            "timeToday": d.timeToday
        ]
        var terms: [[Any]] = []
        if let search = d.searchTerms {
            terms.append([search, d.termLimit ?? 50, 0])
        }
        if let search2 = d.searchTerms2?.trimmingCharacters(in: .whitespacesAndNewlines), !search2.isEmpty {
            terms.append([search2, d.termLimit2 ?? 50, 0])
        }
        if !terms.isEmpty { dict["terms"] = terms }
        if let resched = d.resched { dict["resched"] = resched }
        if let previewDelay = d.previewDelay { dict["previewDelay"] = previewDelay }
        if let searchOrder = d.searchOrder { dict["ankiosSearchOrder"] = searchOrder }
        if let includeTags = d.includeTags { dict["ankiosIncludeTags"] = includeTags }
        if let excludeTags = d.excludeTags { dict["ankiosExcludeTags"] = excludeTags }
        if let previewAgain = d.previewAgain { dict["previewAgain"] = previewAgain }
        if let previewHard = d.previewHard { dict["previewHard"] = previewHard }
        if let previewGood = d.previewGood { dict["previewGood"] = previewGood }
        if let searchOrder2 = d.searchOrder2 { dict["ankiosSearchOrder2"] = searchOrder2 }
        return dict
    }

    // MARK: - Mutations

    func createDeck(name: String, parent: AnkiDeck? = nil) throws {
        let fullName = parent.map { $0.name + "::" + name } ?? name
        if decks.contains(where: { $0.name == fullName }) { return }
        let id = timestampID()
        var next = decks
        next.append(AnkiDeck(
            id: id, name: fullName, mod: Int64(Date().timeIntervalSince1970), usn: -1,
            collapsed: false, browserCollapsed: false, desc: "", dyn: 0, conf: 1,
            extendNew: 0, extendRev: 0, newToday: [0, 0], revToday: [0, 0], lrnToday: [0, 0], timeToday: [0, 0]
        ))
        try saveDecks(next)
        notifyDeckContentAdded()
    }

    /// Anki's Create Filtered Deck: an empty dynamic deck the user fills from its options.
    @discardableResult
    func createFilteredDeck() throws -> AnkiDeck {
        var name = "Baralho Filtrado"
        var suffix = 2
        while decks.contains(where: { $0.name == name }) {
            name = "Baralho Filtrado \(suffix)"
            suffix += 1
        }
        let id = timestampID()
        let deck = AnkiDeck(
            id: id, name: name, mod: Int64(Date().timeIntervalSince1970), usn: -1,
            collapsed: false, browserCollapsed: false, desc: "", dyn: 1, conf: 1,
            extendNew: 0, extendRev: 0, newToday: [0, 0], revToday: [0, 0], lrnToday: [0, 0], timeToday: [0, 0],
            searchTerms: "is:due", termLimit: 100, resched: true, previewDelay: 10, searchOrder: "due",
            previewAgain: FilteredDeckSupport.previewAgainSeconds,
            previewHard: FilteredDeckSupport.previewHardSeconds,
            previewGood: FilteredDeckSupport.previewGoodSeconds
        )
        var next = decks
        next.append(deck)
        try saveDecks(next)
        return self.deck(id: id) ?? deck
    }

    /// Saves a filtered deck's search and rebuilds it, the way Anki's filtered options do.
    func saveFilteredDeck(
        _ deck: AnkiDeck,
        search: String,
        limit: Int,
        order: String,
        reschedule: Bool,
        again: Int,
        hard: Int,
        good: Int,
        search2: String = "",
        limit2: Int = 100,
        order2: String = "due"
    ) throws {
        var next = decks
        guard let idx = next.firstIndex(where: { $0.id == deck.id }) else { return }
        next[idx].searchTerms = search
        next[idx].termLimit = max(1, limit)
        next[idx].searchOrder = order
        next[idx].resched = reschedule
        next[idx].previewAgain = again
        next[idx].previewHard = hard
        next[idx].previewGood = good
        let second = search2.trimmingCharacters(in: .whitespacesAndNewlines)
        next[idx].searchTerms2 = second.isEmpty ? nil : second
        next[idx].termLimit2 = max(1, limit2)
        next[idx].searchOrder2 = order2
        next[idx].mod = Int64(Date().timeIntervalSince1970)
        try saveDecks(next)
        if let saved = self.deck(id: deck.id) {
            try FilteredDeckSupport.rebuild(saved, store: self)
        }
    }

    /// Points every non-filtered child at this deck's preset.
    func applyPresetToSubdecks(of deck: AnkiDeck) throws {
        let live = decks.first { $0.id == deck.id } ?? deck
        let prefix = live.name + "::"
        var next = decks
        var changed = false
        for i in next.indices where next[i].name.hasPrefix(prefix) && !next[i].isFiltered {
            next[i].conf = live.conf
            next[i].mod = Int64(Date().timeIntervalSince1970)
            changed = true
        }
        if changed { try saveDecks(next) }
    }

    func renameDeck(_ deck: AnkiDeck, to newLeaf: String) throws {
        let parts = deck.pathComponents
        let newName: String
        if parts.count <= 1 {
            newName = newLeaf
        } else {
            newName = parts.dropLast().joined(separator: "::") + "::" + newLeaf
        }
        let oldPrefix = deck.name
        var next = decks.map { d -> AnkiDeck in
            var copy = d
            if d.id == deck.id {
                copy.name = newName
            } else if d.name.hasPrefix(oldPrefix + "::") {
                copy.name = newName + String(d.name.dropFirst(oldPrefix.count))
            }
            copy.mod = Int64(Date().timeIntervalSince1970)
            return copy
        }
        try saveDecks(next)
    }

    func deleteDeck(_ deck: AnkiDeck, cardsToo: Bool = true) throws {
        if deck.isFiltered {
            try FilteredDeckSupport.returnHome(deckID: deck.id, store: self)
            let remaining = decks.filter { $0.id != deck.id }
            try saveDecks(remaining.isEmpty ? [Self.fallbackDeck()] : remaining)
            return
        }
        let ids = deckTreeIDs(including: deck.id)
        if cardsToo {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            // Collect notes that have cards in this tree, then delete cards, then
            // drop only notes that no longer have any cards left (Anki-safe).
            var noteIDs: [Int64] = []
            try db.query(
                "SELECT DISTINCT nid FROM cards WHERE did IN (\(placeholders)) OR odid IN (\(placeholders))",
                bind: { stmt in
                    for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                    for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id) }
                }
            ) { stmt in
                noteIDs.append(sqlite3_column_int64(stmt, 0))
            }
            try db.run("DELETE FROM cards WHERE did IN (\(placeholders)) OR odid IN (\(placeholders))") { stmt in
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id) }
            }
            if !noteIDs.isEmpty {
                let nph = noteIDs.map { _ in "?" }.joined(separator: ",")
                try db.run("""
                    DELETE FROM notes WHERE id IN (\(nph))
                    AND id NOT IN (SELECT nid FROM cards)
                """) { stmt in
                    for (i, id) in noteIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                }
            }
        }
        let remaining = decks.filter { !ids.contains($0.id) }
        try saveDecks(remaining.isEmpty ? [Self.fallbackDeck()] : remaining)
    }

    private static func fallbackDeck() -> AnkiDeck {
        AnkiDeck(
            id: 1, name: "Default", mod: Int64(Date().timeIntervalSince1970), usn: -1,
            collapsed: false, browserCollapsed: false, desc: "", dyn: 0, conf: 1,
            extendNew: 0, extendRev: 0, newToday: [0, 0], revToday: [0, 0], lrnToday: [0, 0], timeToday: [0, 0]
        )
    }

    func addNote(mid: Int64, did: Int64, fields: [String], tags: String) throws {
        guard let model = notetype(id: mid) else { throw SQLiteError.exec("Missing notetype") }
        let nid = timestampID()
        let now = Int64(Date().timeIntervalSince1970)
        let flds = fields.joined(separator: "\u{1f}")
        let sfld = fields.first ?? ""
        let guid = randomGUID()
        let csum = fieldChecksum(sfld)
        try db.run("""
            INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
            VALUES (?, ?, ?, ?, -1, ?, ?, ?, ?, 0, '')
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, nid)
            try SQLiteDatabase.bindText(stmt, 2, guid)
            SQLiteDatabase.bindInt64(stmt, 3, mid)
            SQLiteDatabase.bindInt64(stmt, 4, now)
            try SQLiteDatabase.bindText(stmt, 5, tags.hasPrefix(" ") ? tags : " \(tags) ")
            try SQLiteDatabase.bindText(stmt, 6, flds)
            try SQLiteDatabase.bindText(stmt, 7, sfld)
            SQLiteDatabase.bindInt64(stmt, 8, csum)
        }

        let ords: [Int]
        if model.isCloze {
            ords = ClozeHelper.ords(in: fields)
        } else {
            let active = activeTemplateOrds(model: model, fields: fields)
            ords = active.isEmpty ? [0] : active
        }
        for ord in ords {
            let cid = timestampID()
            try db.run("""
                INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                VALUES (?, ?, ?, ?, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
            """) { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, cid)
                SQLiteDatabase.bindInt64(stmt, 2, nid)
                SQLiteDatabase.bindInt64(stmt, 3, did)
                SQLiteDatabase.bindInt(stmt, 4, ord)
                SQLiteDatabase.bindInt64(stmt, 5, now)
                SQLiteDatabase.bindInt(stmt, 6, Int(nid % 1_000_000))
            }
            // tiny sleep to keep ids unique when looping fast
            Thread.sleep(forTimeInterval: 0.001)
        }
        try registerTags(from: tags)
        try touchCol()
        try refreshCounts()
    }

    func updateNote(_ note: AnkiNote, fields: [String], tags: String) throws {
        let flds = fields.joined(separator: "\u{1f}")
        let sfld = fields.first ?? ""
        let now = Int64(Date().timeIntervalSince1970)
        try db.run("""
            UPDATE notes SET mod=?, tags=?, flds=?, sfld=?, csum=? WHERE id=?
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, now)
            try SQLiteDatabase.bindText(stmt, 2, tags.hasPrefix(" ") ? tags : " \(tags) ")
            try SQLiteDatabase.bindText(stmt, 3, flds)
            try SQLiteDatabase.bindText(stmt, 4, sfld)
            SQLiteDatabase.bindInt64(stmt, 5, self.fieldChecksum(sfld))
            SQLiteDatabase.bindInt64(stmt, 6, note.id)
        }
        if let model = notetype(id: note.mid) {
            if model.isCloze {
                try syncClozeCards(noteID: note.id, mid: note.mid, fields: fields)
            } else {
                // Re-evaluate optional/conditional templates (e.g. Add Reverse).
                try regenerateCards(forNoteID: note.id)
            }
        }
        try registerTags(from: tags)
        try touchCol()
    }

    /// Keep col.tags in sync for browser sidebar (Anki tag registry).
    func registerTags(from tagsString: String) throws {
        let parts = tagsString.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        var next = tags
        var changed = false
        for t in parts where next[t] == nil {
            next[t] = -1
            changed = true
        }
        guard changed else { return }
        tags = next
        let json = CollectionSchema.encodeJSON(next)
        try db.run("UPDATE col SET tags = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
    }

    func rebuildTagRegistry() throws {
        var next: [String: Int] = [:]
        try db.query("SELECT tags FROM notes") { stmt in
            let raw = SQLiteDatabase.text(stmt, 0)
            for t in raw.split(whereSeparator: { $0.isWhitespace }).map(String.init) where !t.isEmpty {
                next[t] = -1
            }
        }
        tags = next
        let json = CollectionSchema.encodeJSON(next)
        try db.run("UPDATE col SET tags = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
    }

    /// Add/remove cards when cloze numbers or note-type templates change (Anki regenerate).
    func syncNoteCards(
        noteID: Int64,
        mid: Int64,
        wanted: Set<Int>,
        unsuspendRestoredEmpty: Bool,
        isCloze: Bool
    ) throws {
        var existing: [(id: Int64, ord: Int, did: Int64)] = []
        try db.query("SELECT id, ord, did FROM cards WHERE nid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) { stmt in
            existing.append((
                sqlite3_column_int64(stmt, 0),
                Int(sqlite3_column_int(stmt, 1)),
                sqlite3_column_int64(stmt, 2)
            ))
        }

        let existingOrds = Set(existing.map(\.ord))
        let toDelete = existing.filter { !wanted.contains($0.ord) }
        let toAdd = wanted.subtracting(existingOrds)
        let homeDid = existing.first?.did ?? decks.first?.id ?? 1
        let now = Int64(Date().timeIntervalSince1970)

        for card in toDelete {
            // Prefer suspend over hard-delete if the card has progress.
            if let full = try fetchCard(id: card.id), full.reps > 0 || full.ivl > 0 {
                var c = full
                c.queue = -1
                c.mod = now
                try updateCard(c)
            } else {
                try db.run("DELETE FROM cards WHERE id = ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, card.id)
                })
            }
        }

        for ord in toAdd.sorted() {
            let due = isCloze
                ? Int(noteID % 1_000_000) + ord
                : Int(noteID % 1_000_000)
            let cid = timestampID()
            try db.run("""
                INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                VALUES (?, ?, ?, ?, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
            """) { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, cid)
                SQLiteDatabase.bindInt64(stmt, 2, noteID)
                SQLiteDatabase.bindInt64(stmt, 3, homeDid)
                SQLiteDatabase.bindInt(stmt, 4, ord)
                SQLiteDatabase.bindInt64(stmt, 5, now)
                SQLiteDatabase.bindInt(stmt, 6, due)
            }
            Thread.sleep(forTimeInterval: 0.001)
        }

        if unsuspendRestoredEmpty {
            // Unsuspend cards that are wanted again and were only auto-suspended as empty cloze.
            for card in existing where wanted.contains(card.ord) {
                if let full = try fetchCard(id: card.id), full.queue == -1, full.reps == 0, full.ivl == 0 {
                    var c = full
                    c.queue = 0
                    c.type = 0
                    c.mod = now
                    try updateCard(c)
                }
            }
        }
        _ = mid
    }

    private func syncClozeCards(noteID: Int64, mid: Int64, fields: [String]) throws {
        var wanted = Set(ClozeHelper.ords(in: fields))
        if wanted.isEmpty { wanted = [0] }
        try syncNoteCards(
            noteID: noteID,
            mid: mid,
            wanted: wanted,
            unsuspendRestoredEmpty: true,
            isCloze: true
        )
        try refreshCounts()
    }

    func deleteNotes(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.run("DELETE FROM cards WHERE nid IN (\(placeholders))") { stmt in
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        }
        try db.run("DELETE FROM notes WHERE id IN (\(placeholders))") { stmt in
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
        }
        try touchCol()
        try refreshCounts()
    }

    func setCardsFlag(_ ids: [Int64], flag: Int) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.run("UPDATE cards SET flags = (flags & ~7) | ?, mod = ? WHERE id IN (\(placeholders))") { stmt in
            SQLiteDatabase.bindInt(stmt, 1, min(max(flag, 0), 7))
            SQLiteDatabase.bindInt64(stmt, 2, Int64(Date().timeIntervalSince1970))
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 3), id) }
        }
        try touchCol()
    }

    func setCardsQueue(_ ids: [Int64], queue: Int) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.run("UPDATE cards SET queue = ?, mod = ? WHERE id IN (\(placeholders))") { stmt in
            SQLiteDatabase.bindInt(stmt, 1, queue)
            SQLiteDatabase.bindInt64(stmt, 2, Int64(Date().timeIntervalSince1970))
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 3), id) }
        }
        try touchCol()
        try refreshCounts()
    }

    /// Restore buried/suspended cards to the queue matching their type (Anki behavior).
    func restoreCardsToActiveQueue(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard var card = try fetchCard(id: id) else { continue }
            switch card.type {
            case 0: card.queue = 0
            case 1, 3: card.queue = card.due > Int(Date().timeIntervalSince1970) && card.ivl == 0 ? 1 : (card.type == 1 ? 1 : 1)
            case 2: card.queue = 2
            default: card.queue = 0
            }
            // Day-learn cards
            if card.type == 1 || card.type == 3 {
                if card.due < 1_000_000_000 { // due is a day number, not timestamp
                    card.queue = 3
                } else {
                    card.queue = 1
                }
            }
            card.mod = Int64(Date().timeIntervalSince1970)
            try updateCard(card)
        }
        try refreshCounts()
    }

    func unburyCards(_ ids: [Int64]) throws {
        let buried = try ids.filter { id in
            guard let c = try fetchCard(id: id) else { return false }
            return c.queue == -2 || c.queue == -3
        }
        try restoreCardsToActiveQueue(buried)
    }

    func unsuspendCards(_ ids: [Int64]) throws {
        let suspended = try ids.filter { id in
            guard let c = try fetchCard(id: id) else { return false }
            return c.queue == -1
        }
        try restoreCardsToActiveQueue(suspended)
    }

    func unburyAll() throws {
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE queue IN (-2,-3)") { stmt in
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        try unburyCards(ids)
    }

    /// Unbury cards in a deck and its subdecks (Anki overview “Unbury”).
    /// `-2` is sibling bury, `-3` is manual bury.
    func unburyDeckTree(deckID: Int64, queues: Set<Int> = [-2, -3]) throws {
        let ids = deckTreeIDs(including: deckID)
        let wanted = queues.isEmpty ? [-2, -3] : queues.sorted()
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let qph = wanted.map { _ in "?" }.joined(separator: ",")
        var cardIDs: [Int64] = []
        try db.query(
            "SELECT id FROM cards WHERE did IN (\(ph)) AND queue IN (\(qph))",
            bind: { stmt in
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                for (i, queue) in wanted.enumerated() {
                    SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1 + i), queue)
                }
            }
        ) { stmt in
            cardIDs.append(sqlite3_column_int64(stmt, 0))
        }
        try unburyCards(cardIDs)
        try refreshCounts()
    }

    /// Anki “Forget” / reset: card becomes new again (queue 0), progress cleared.
    // resetCards(_:restoreOriginalPosition:clearCounts:) lives in CardOperations.swift (Anki Forget/Reset).

    func moveCards(_ ids: [Int64], toDeck did: Int64) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.run("UPDATE cards SET did = ?, mod = ? WHERE id IN (\(placeholders))") { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, did)
            SQLiteDatabase.bindInt64(stmt, 2, Int64(Date().timeIntervalSince1970))
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 3), id) }
        }
        try touchCol()
        try refreshCounts()
    }

    // MARK: - Search / Browser

    struct BrowserRow: Identifiable, Hashable {
        var id: Int64 { card.id }
        var card: AnkiCard
        var note: AnkiNote
        var deckName: String
        var notetypeName: String
    }

    func search(query: String, limit: Int = 500) throws -> [BrowserRow] {
        // Support Anki-style OR by unioning clause groups
        var parts = [query]
        for sep in [" OR ", " or "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count > 1 {
            var seen = Set<Int64>()
            var rows: [BrowserRow] = []
            for part in parts {
                for row in try search(query: part, limit: limit) where seen.insert(row.id).inserted {
                    rows.append(row)
                    if rows.count >= limit { return rows }
                }
            }
            return rows
        }

        // Simplified Anki-like search
        var sql = """
        SELECT c.id FROM cards c JOIN notes n ON n.id = c.nid WHERE 1=1
        """
        var binds: [(OpaquePointer) -> Void] = []
        let tokens = tokenizeSearch(query)

        for rawToken in tokens {
            let negated = rawToken.hasPrefix("-")
            let token = negated ? String(rawToken.dropFirst()) : rawToken
            let notSQL = negated ? " NOT" : ""
            let andNot = negated ? " AND NOT" : " AND"

            if token.hasPrefix("deck:") {
                if token == "deck:filtered" {
                    sql += negated ? " AND c.odid = 0" : " AND c.odid != 0"
                } else {
                    let parsed = parseDeckSearchToken(token)
                    if parsed.name == "current" {
                        let currentID = currentDeckID()
                            ?? recommendedStudyDeck?.id
                            ?? decks.first(where: { $0.name != "Default" })?.id
                            ?? decks.first?.id
                        if let currentID {
                            let tree = deckTreeIDs(including: currentID)
                            let list = tree.map(String.init).joined(separator: ",")
                            sql += "\(andNot) (c.did IN (\(list)))"
                        } else {
                            sql += negated ? "" : " AND 0"
                        }
                    } else {
                        let matching = deckIDs(matchingSearchName: parsed.name, exact: parsed.exact)
                        if matching.isEmpty {
                            sql += negated ? "" : " AND 0"
                        } else {
                            let ph = matching.map { _ in "?" }.joined(separator: ",")
                            sql += "\(andNot) (c.did IN (\(ph)))"
                        }
                    }
                }
            } else if token == "is:new" {
                sql += "\(andNot) (c.type = 0)"
            } else if token == "is:learn" {
                sql += "\(andNot) (c.type IN (1, 3))"
            } else if token == "is:review" {
                sql += "\(andNot) (c.type IN (2, 3))"
            } else if token == "is:suspended" {
                sql += "\(andNot) (c.queue = -1)"
            } else if token == "is:buried" {
                sql += "\(andNot) (c.queue IN (-2,-3))"
            } else if token == "is:due" {
                let day = schedDay()
                let learnCutoff = Int(Date().timeIntervalSince1970) + (conf["collapseTime"] as? Int ?? 1200)
                sql += "\(andNot) ((c.queue IN (2, 3) AND c.due <= \(day)) OR (c.queue IN (1, 4) AND c.due <= \(learnCutoff)))"
            } else if token == "is:old" {
                sql += "\(andNot) (c.type != 0)"
            } else if token == "is:buried-sibling" {
                sql += "\(andNot) (c.queue = -2)"
            } else if token == "is:buried-manually" {
                sql += "\(andNot) (c.queue = -3)"
            } else if token == "is:leech" || token == "tag:leech" {
                sql += "\(andNot) (n.tags LIKE '% leech %')"
            } else if token.hasPrefix("prop:pos") {
                if let (op, n) = Self.parseProp(token, key: "pos") {
                    sql += "\(andNot) (c.type = 0 AND (CASE WHEN c.odue != 0 THEN c.odue ELSE c.due END) \(op) \(n))"
                }
            } else if token.hasPrefix("flag:") {
                let raw = String(token.dropFirst(5)).lowercased()
                let f: Int?
                switch raw {
                case "red", "1": f = 1
                case "orange", "2": f = 2
                case "green", "3": f = 3
                case "blue", "4": f = 4
                case "pink", "5": f = 5
                case "turquoise", "teal", "6": f = 6
                case "purple", "7": f = 7
                case "none", "0": f = 0
                default: f = Int(raw)
                }
                if let f {
                    sql += "\(andNot) ((c.flags & 7) = \(f))"
                }
            } else if token.hasPrefix("added:") {
                let days = max(Int(token.dropFirst(6)) ?? 1, 1)
                let since = searchDayStart(days: days) * 1000
                sql += "\(andNot) (c.id > \(since))"
            } else if token.hasPrefix("rated:") {
                // rated:1  or  rated:1:1 (days:ease). Day 1 is the current scheduling day.
                let bits = token.split(separator: ":").map(String.init)
                let days = max(Int(bits.count > 1 ? bits[1] : "1") ?? 1, 1)
                let ease = bits.count > 2 ? Int(bits[2]) : nil
                let since = searchDayStart(days: days)
                if let ease {
                    sql += "\(andNot) (c.id IN (SELECT cid FROM revlog WHERE id >= \(since * 1000) AND ease = \(ease)))"
                } else {
                    sql += "\(andNot) (c.id IN (SELECT cid FROM revlog WHERE id >= \(since * 1000)))"
                }
            } else if token.hasPrefix("note:") {
                let name = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let mids = notetypes.filter { $0.name.localizedCaseInsensitiveContains(name) || $0.name == name }.map(\.id)
                if mids.isEmpty {
                    sql += negated ? "" : " AND 0"
                } else {
                    let ph = mids.map { _ in "?" }.joined(separator: ",")
                    sql += "\(andNot) (n.mid IN (\(ph)))"
                }
            } else if token == "tag:marked" || token == "is:marked" {
                sql += "\(andNot) (n.tags LIKE '% marked %')"
            } else if token.hasPrefix("nid:") {
                if let n = Int64(token.dropFirst(4)) { sql += "\(andNot) (n.id = \(n))" }
            } else if token.hasPrefix("cid:") {
                if let n = Int64(token.dropFirst(4)) { sql += "\(andNot) (c.id = \(n))" }
            } else if token.hasPrefix("prop:due") {
                if let (op, n) = Self.parseProp(token, key: "due") {
                    let day = schedDay() + n
                    let cutoff = schedDayStartTimestamp() + 86_400
                    let dueExpr = "(CASE WHEN c.odue != 0 THEN c.odue ELSE c.due END)"
                    sql += "\(andNot) ((c.queue IN (2, 3) AND \(dueExpr) \(op) \(day)) OR (c.queue IN (1, 4) AND ((\(dueExpr) - \(cutoff)) / 86400) \(op) \(n)))"
                }
            } else if token.hasPrefix("card:") {
                let name = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let ords = notetypes.flatMap { nt in
                    nt.tmpls.filter { $0.name.localizedCaseInsensitiveContains(name) }.map(\.ord)
                }
                if ords.isEmpty {
                    sql += negated ? "" : " AND 0"
                } else {
                    let uniq = Array(Set(ords))
                    let ph = uniq.map { "\($0)" }.joined(separator: ",")
                    sql += "\(andNot) (c.ord IN (\(ph)))"
                }
            } else if token.hasPrefix("prop:ivl") {
                if let (op, n) = Self.parseProp(token, key: "ivl") {
                    sql += "\(andNot) (c.ivl \(op) \(n))"
                }
            } else if token.hasPrefix("prop:reps") {
                if let (op, n) = Self.parseProp(token, key: "reps") {
                    sql += "\(andNot) (c.reps \(op) \(n))"
                }
            } else if token.hasPrefix("prop:lapses") {
                if let (op, n) = Self.parseProp(token, key: "lapses") {
                    sql += "\(andNot) (c.lapses \(op) \(n))"
                }
            } else if token.hasPrefix("prop:ease") {
                if let (op, n) = Self.parsePropScaled(token, key: "ease", scale: 1000) {
                    sql += "\(andNot) (c.factor \(op) \(n))"
                }
            } else if token.hasPrefix("prop:factor") {
                if let (op, n) = Self.parseProp(token, key: "factor") {
                    sql += "\(andNot) (c.factor \(op) \(n))"
                }
            } else if token.hasPrefix("introduced:") {
                let days = max(Int(token.dropFirst("introduced:".count)) ?? 1, 1)
                let since = searchDayStart(days: days) * 1000
                sql += "\(andNot) (c.id IN (SELECT cid FROM revlog GROUP BY cid HAVING MIN(id) >= \(since)))"
            } else if token == "dupe:" || token.hasPrefix("dupe:") {
                let raw = String(token.dropFirst(5))
                if let mid = Int64(raw), mid > 0 {
                    sql += "\(andNot) (n.mid = \(mid) AND EXISTS (SELECT 1 FROM notes n2 WHERE n2.mid = n.mid AND n2.sfld = n.sfld AND n2.id != n.id))"
                } else {
                    sql += "\(andNot) (EXISTS (SELECT 1 FROM notes n2 WHERE n2.mid = n.mid AND n2.sfld = n.sfld AND n2.id != n.id))"
                }
            } else if token.hasPrefix("tag:") {
                let tag = String(token.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if tag == "*" {
                    sql += "\(andNot) (trim(n.tags) != '')"
                } else {
                    sql += "\(andNot) (n.tags LIKE ?)"
                }
            } else if token.hasPrefix("field:") {
                // field:value  or  field:Front:value
                sql += "\(andNot) (n.flds LIKE ?)"
            } else if isNamedFieldSearchToken(token) {
                // Anki `Front:texto` shorthand — LIKE then narrow in applyNamedFieldFilters.
                sql += "\(andNot) (n.flds LIKE ?)"
            } else if !token.isEmpty {
                let term = stripSearchQuotes(token)
                if !term.isEmpty {
                    sql += "\(andNot) (n.sfld LIKE ? OR n.flds LIKE ? OR n.tags LIKE ?)"
                }
            }
            _ = notSQL
            _ = binds
        }
        sql += " ORDER BY n.sfld COLLATE NOCASE LIMIT \(limit)"

        // Rebuild with proper binding
        var cardIDs: [Int64] = []
        try db.query(sql, bind: { stmt in
            var idx: Int32 = 1
            for rawToken in tokens {
                let token = rawToken.hasPrefix("-") ? String(rawToken.dropFirst()) : rawToken
                if token.hasPrefix("deck:") {
                    if token == "deck:filtered" { continue }
                    let parsed = self.parseDeckSearchToken(token)
                    if parsed.name != "current" {
                        let matching = self.deckIDs(matchingSearchName: parsed.name, exact: parsed.exact)
                        for id in matching {
                            SQLiteDatabase.bindInt64(stmt, idx, id)
                            idx += 1
                        }
                    }
                } else if token.hasPrefix("tag:") {
                    let tag = String(token.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if tag != "*" && token != "tag:marked" {
                        try SQLiteDatabase.bindText(stmt, idx, "% \(tag) %")
                        idx += 1
                    }
                } else if token.hasPrefix("note:") {
                    let name = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let mids = self.notetypes.filter { $0.name.localizedCaseInsensitiveContains(name) || $0.name == name }.map(\.id)
                    for mid in mids {
                        SQLiteDatabase.bindInt64(stmt, idx, mid)
                        idx += 1
                    }
                } else if token.hasPrefix("field:") {
                    let rest = String(token.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    // Prefer last segment after ':' as the search text (field:Name:value)
                    let value = rest.split(separator: ":").map(String.init).last ?? rest
                    try SQLiteDatabase.bindText(stmt, idx, "%\(value)%")
                    idx += 1
                } else if self.isNamedFieldSearchToken(token) {
                    let value = self.namedFieldSearchValue(token)
                    try SQLiteDatabase.bindText(stmt, idx, "%\(value)%")
                    idx += 1
                } else if token.hasPrefix("flag:") || token.hasPrefix("is:") || token.hasPrefix("added:") || token.hasPrefix("rated:") || token.hasPrefix("introduced:") || token.hasPrefix("dupe:") || token.hasPrefix("nid:") || token.hasPrefix("cid:") || token.hasPrefix("prop:") || token.hasPrefix("card:") || token == "deck:filtered" || token.isEmpty {
                    continue
                } else {
                    let term = self.stripSearchQuotes(token)
                    guard !term.isEmpty else { continue }
                    let q = "%\(term)%"
                    try SQLiteDatabase.bindText(stmt, idx, q); idx += 1
                    try SQLiteDatabase.bindText(stmt, idx, q); idx += 1
                    try SQLiteDatabase.bindText(stmt, idx, q); idx += 1
                }
            }
        }) { stmt in
            cardIDs.append(sqlite3_column_int64(stmt, 0))
        }

        var rows: [BrowserRow] = []
        for cid in cardIDs {
            guard let card = try fetchCard(id: cid),
                  let note = try fetchNote(id: card.nid) else { continue }
            let deckName = deck(id: card.did)?.name ?? "?"
            let ntName = notetype(id: note.mid)?.name ?? "?"
            rows.append(BrowserRow(card: card, note: note, deckName: deckName, notetypeName: ntName))
        }
        return applyNamedFieldFilters(rows, tokens: tokens)
    }

    private static let reservedSearchPrefixes: Set<String> = [
        "deck", "tag", "note", "card", "flag", "is", "prop", "added", "rated", "nid", "cid", "field"
    ]

    private func isNamedFieldSearchToken(_ token: String) -> Bool {
        guard let colon = token.firstIndex(of: ":") else { return false }
        let name = String(token[..<colon])
        guard !name.isEmpty, !Self.reservedSearchPrefixes.contains(name.lowercased()) else { return false }
        return notetypes.contains { nt in
            nt.flds.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    private func namedFieldSearchValue(_ token: String) -> String {
        guard let colon = token.firstIndex(of: ":") else { return token }
        return String(token[token.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// `field:Front:value` / `Front:value` — narrow LIKE hits to the named field segment.
    private func applyNamedFieldFilters(_ rows: [BrowserRow], tokens: [String]) -> [BrowserRow] {
        var result = rows
        for rawToken in tokens {
            let negated = rawToken.hasPrefix("-")
            let token = negated ? String(rawToken.dropFirst()) : rawToken
            let fieldName: String
            let value: String
            if token.hasPrefix("field:") {
                let rest = String(token.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard let colon = rest.firstIndex(of: ":") else { continue }
                fieldName = String(rest[..<colon])
                value = String(rest[rest.index(after: colon)...])
            } else if isNamedFieldSearchToken(token) {
                guard let colon = token.firstIndex(of: ":") else { continue }
                fieldName = String(token[..<colon])
                value = String(token[token.index(after: colon)...])
            } else {
                continue
            }
            guard !fieldName.isEmpty, !value.isEmpty else { continue }
            result = result.filter { row in
                guard let nt = notetype(id: row.note.mid),
                      let idx = nt.flds.firstIndex(where: { $0.name.caseInsensitiveCompare(fieldName) == .orderedSame }),
                      idx < row.note.fields.count else {
                    return negated
                }
                let hit = row.note.fields[idx].localizedCaseInsensitiveContains(value)
                return negated ? !hit : hit
            }
        }
        return result
    }

    private func tokenizeSearch(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in query {
            if ch == "\"" {
                current.append(ch)
                inQuotes.toggle()
                continue
            }
            if ch == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private struct DeckSearchToken {
        var name: String
        var exact: Bool
    }

    private func parseDeckSearchToken(_ token: String) -> DeckSearchToken {
        let raw = String(token.dropFirst(5))
        let exact = raw.hasPrefix("\"") && raw.hasSuffix("\"")
        let name = stripSearchQuotes(raw)
        return DeckSearchToken(name: name, exact: exact)
    }

    private func stripSearchQuotes(_ token: String) -> String {
        guard token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 else { return token }
        return String(token.dropFirst().dropLast())
    }

    private func deckIDs(matchingSearchName name: String, exact: Bool) -> [Int64] {
        let roots: [AnkiDeck]
        if exact {
            roots = decks.filter { $0.name == name }
        } else {
            roots = decks.filter { $0.name.localizedCaseInsensitiveContains(name) || $0.name == name }
        }
        // Anki `deck:Foo` includes the whole subdeck tree under each match.
        var ids = Set<Int64>()
        for root in roots {
            for id in deckTreeIDs(including: root.id) { ids.insert(id) }
        }
        return Array(ids)
    }

    // MARK: - Stats helpers

    private func deckFilterSQL(deckID: Int64?, alias: String = "c") -> (clause: String, ids: [Int64]) {
        guard let deckID else { return ("", []) }
        let ids = deckTreeIDs(including: deckID)
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        return (" AND \(alias).did IN (\(ph))", ids)
    }

    private func bindDeckIDs(_ stmt: OpaquePointer, ids: [Int64], startingAt: Int32) {
        for (i, id) in ids.enumerated() {
            SQLiteDatabase.bindInt64(stmt, startingAt + Int32(i), id)
        }
    }

    func todayReviewCount(deckID: Int64? = nil) throws -> Int {
        let start = schedDayStartTimestamp() * 1000
        let filter = deckFilterSQL(deckID: deckID)
        if filter.ids.isEmpty {
            return try db.scalarInt("SELECT COUNT(*) FROM revlog WHERE id >= ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, start)
            })
        }
        return try db.scalarInt("""
            SELECT COUNT(*) FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id >= ? \(filter.clause)
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }
    }

    func todayReviewTimeMS(deckID: Int64? = nil) throws -> Int {
        let start = schedDayStartTimestamp() * 1000
        let filter = deckFilterSQL(deckID: deckID)
        if filter.ids.isEmpty {
            return try db.scalarInt("SELECT COALESCE(SUM(time),0) FROM revlog WHERE id >= ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, start)
            })
        }
        return try db.scalarInt("""
            SELECT COALESCE(SUM(r.time),0) FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id >= ? \(filter.clause)
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }
    }

    /// day offset (0=today) -> review count
    func reviewsLastDays(_ days: Int, deckID: Int64? = nil) throws -> [Int: Int] {
        var map: [Int: Int] = [:]
        let now = Int64(Date().timeIntervalSince1970)
        let filter = deckFilterSQL(deckID: deckID)
        for day in 0..<days {
            let end = now - Int64(day * 86400)
            let start = end - 86400
            let count: Int
            if filter.ids.isEmpty {
                count = try db.scalarInt("SELECT COUNT(*) FROM revlog WHERE id >= ? AND id < ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, start * 1000)
                    SQLiteDatabase.bindInt64($0, 2, end * 1000)
                })
            } else {
                count = try db.scalarInt("""
                    SELECT COUNT(*) FROM revlog r JOIN cards c ON c.id = r.cid
                    WHERE r.id >= ? AND r.id < ? \(filter.clause)
                """) { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, start * 1000)
                    SQLiteDatabase.bindInt64(stmt, 2, end * 1000)
                    self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 3)
                }
            }
            map[day] = count
        }
        return map
    }

    func revlogRecent(limit: Int = 200, deckID: Int64? = nil) throws -> [AnkiRevlog] {
        var rows: [AnkiRevlog] = []
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT * FROM revlog ORDER BY id DESC LIMIT ?"
        } else {
            sql = """
            SELECT r.* FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE 1=1 \(filter.clause) ORDER BY r.id DESC LIMIT ?
            """
        }
        try db.query(sql, bind: { stmt in
            var idx: Int32 = 1
            if !filter.ids.isEmpty {
                self.bindDeckIDs(stmt, ids: filter.ids, startingAt: idx)
                idx += Int32(filter.ids.count)
            }
            SQLiteDatabase.bindInt(stmt, idx, limit)
        }) { stmt in
            rows.append(AnkiRevlog(
                id: sqlite3_column_int64(stmt, 0),
                cid: sqlite3_column_int64(stmt, 1),
                usn: Int(sqlite3_column_int(stmt, 2)),
                ease: Int(sqlite3_column_int(stmt, 3)),
                ivl: Int(sqlite3_column_int(stmt, 4)),
                lastIvl: Int(sqlite3_column_int(stmt, 5)),
                factor: Int(sqlite3_column_int(stmt, 6)),
                time: Int(sqlite3_column_int(stmt, 7)),
                type: Int(sqlite3_column_int(stmt, 8))
            ))
        }
        return rows
    }

    func futureDue(days: Int = 30, deckID: Int64? = nil) throws -> [Int: Int] {
        let day = schedDay()
        var map: [Int: Int] = [:]
        let filter = deckFilterSQL(deckID: deckID)
        try db.query("""
            SELECT due, COUNT(*) FROM cards c WHERE queue = 2 AND due BETWEEN ? AND ? \(filter.clause) GROUP BY due
        """) { stmt in
            SQLiteDatabase.bindInt(stmt, 1, day)
            SQLiteDatabase.bindInt(stmt, 2, day + days)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 3)
        } map: { stmt in
            let due = Int(sqlite3_column_int(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            map[due - day] = count
        }
        return map
    }

    /// Answer button counts from revlog (ease 1…4).
    func answerButtonCounts(limit: Int = 2000, deckID: Int64? = nil) throws -> [Int: Int] {
        var map: [Int: Int] = [1: 0, 2: 0, 3: 0, 4: 0]
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT ease, COUNT(*) FROM revlog WHERE ease BETWEEN 1 AND 4 GROUP BY ease ORDER BY ease"
        } else {
            sql = """
            SELECT r.ease, COUNT(*) FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.ease BETWEEN 1 AND 4 \(filter.clause) GROUP BY r.ease ORDER BY r.ease
            """
        }
        try db.query(sql, bind: { stmt in
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1)
        }) { stmt in
            let ease = Int(sqlite3_column_int(stmt, 0))
            map[ease] = Int(sqlite3_column_int(stmt, 1))
        }
        _ = limit
        return map
    }

    /// Interval histogram buckets (days) for mature review cards.
    func intervalHistogram(buckets: [Int] = [1, 3, 7, 14, 30, 90, 180, 365], deckID: Int64? = nil) throws -> [(label: String, count: Int)] {
        var counts = Array(repeating: 0, count: buckets.count + 1)
        let filter = deckFilterSQL(deckID: deckID)
        try db.query("SELECT ivl FROM cards c WHERE queue = 2 AND type = 2 \(filter.clause)", bind: {
            self.bindDeckIDs($0, ids: filter.ids, startingAt: 1)
        }) { stmt in
            let ivl = Int(sqlite3_column_int(stmt, 0))
            if let idx = buckets.firstIndex(where: { ivl <= $0 }) {
                counts[idx] += 1
            } else {
                counts[buckets.count] += 1
            }
        }
        var result: [(String, Int)] = []
        var prev = 0
        for (i, b) in buckets.enumerated() {
            result.append(("\(prev + 1)–\(b)d", counts[i]))
            prev = b
        }
        result.append((">\(buckets.last ?? 365)d", counts[buckets.count]))
        return result
    }

    /// Review cards due on each day offset, for the easy-day load balancer of one preset.
    func dueCountsForPreset(_ configID: Int64, today: Int, days: Int = 100) -> [Int] {
        let ids = decks.filter { $0.conf == configID && !$0.isFiltered }.map(\.id)
        var counts = Array(repeating: 0, count: max(days, 1))
        guard !ids.isEmpty else { return counts }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT due - ?, COUNT(*) FROM cards
        WHERE queue = 2 AND due >= ? AND due < ? AND did IN (\(placeholders))
        GROUP BY due
        """
        try? db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt(stmt, 1, today)
            SQLiteDatabase.bindInt(stmt, 2, today)
            SQLiteDatabase.bindInt(stmt, 3, today + days)
            for (i, id) in ids.enumerated() {
                SQLiteDatabase.bindInt64(stmt, Int32(i + 4), id)
            }
        }) { stmt in
            let offset = Int(sqlite3_column_int(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            if offset >= 0 && offset < counts.count { counts[offset] = count }
        }
        return counts
    }

    struct ReviewDayPoint: Identifiable, Sendable {
        var id: Int { offset }
        var offset: Int
        var learn: Int
        var young: Int
        var mature: Int
        var relearn: Int
        var filtered: Int
    }

    struct TrueRetention: Sendable {
        var youngPass = 0
        var youngFail = 0
        var maturePass = 0
        var matureFail = 0

        var youngPercent: Double { percent(youngPass, youngFail) }
        var maturePercent: Double { percent(maturePass, matureFail) }

        private func percent(_ pass: Int, _ fail: Int) -> Double {
            let total = pass + fail
            guard total > 0 else { return 0 }
            return Double(pass) / Double(total) * 100
        }
    }

    /// Anki's Reviews graph: learning, young, mature, relearn and filtered, per day.
    func reviewsByType(days: Int, deckID: Int64? = nil) throws -> [ReviewDayPoint] {
        var points = (0..<days).map { ReviewDayPoint(offset: $0, learn: 0, young: 0, mature: 0, relearn: 0, filtered: 0) }
        let now = Int(Date().timeIntervalSince1970)
        let start = Int64(now - days * 86_400) * 1000
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT id, type, lastIvl FROM revlog WHERE id >= ?"
        } else {
            sql = """
            SELECT r.id, r.type, r.lastIvl FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id >= ? \(filter.clause)
            """
        }
        try db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            let stamp = Int(sqlite3_column_int64(stmt, 0) / 1000)
            let type = Int(sqlite3_column_int(stmt, 1))
            let lastIvl = Int(sqlite3_column_int(stmt, 2))
            let offset = (now - stamp) / 86_400
            guard offset >= 0, offset < points.count else { return }
            switch type {
            case 0: points[offset].learn += 1
            case 1:
                if lastIvl < 21 { points[offset].young += 1 } else { points[offset].mature += 1 }
            case 2: points[offset].relearn += 1
            default: points[offset].filtered += 1
            }
        }
        return points
    }

    /// Anki true retention: review answers only. Young is an interval under 21 days.
    func trueRetention(days: Int, deckID: Int64? = nil) throws -> TrueRetention {
        var result = TrueRetention()
        let start = Int64(Date().timeIntervalSince1970) - Int64(days) * 86_400
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT ease, lastIvl FROM revlog WHERE type = 1 AND id >= ?"
        } else {
            sql = """
            SELECT r.ease, r.lastIvl FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.type = 1 AND r.id >= ? \(filter.clause)
            """
        }
        try db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start * 1000)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            let ease = Int(sqlite3_column_int(stmt, 0))
            let lastIvl = Int(sqlite3_column_int(stmt, 1))
            let passed = ease != 1
            if lastIvl < 21 {
                if passed { result.youngPass += 1 } else { result.youngFail += 1 }
            } else if passed {
                result.maturePass += 1
            } else {
                result.matureFail += 1
            }
        }
        return result
    }

    /// Ease factor histogram for review cards. Factor 2500 is 250%.
    func easeHistogram(deckID: Int64? = nil) throws -> [(label: String, count: Int)] {
        let labels = ["<130%"] + (13...25).map { "\($0 * 10)%" } + [">250%"]
        var counts = Array(repeating: 0, count: labels.count)
        let filter = deckFilterSQL(deckID: deckID)
        try db.query("SELECT factor FROM cards c WHERE type = 2 \(filter.clause)", bind: {
            self.bindDeckIDs($0, ids: filter.ids, startingAt: 1)
        }) { stmt in
            let factor = Int(sqlite3_column_int(stmt, 0))
            let percent = factor / 10
            let index: Int
            if percent < 130 {
                index = 0
            } else if percent > 250 {
                index = counts.count - 1
            } else {
                index = 1 + (percent - 130) / 10
            }
            if counts.indices.contains(index) { counts[index] += 1 }
        }
        return Array(zip(labels, counts))
    }

    func cardStateCounts(deckID: Int64? = nil) throws -> (new: Int, learn: Int, review: Int, suspended: Int, buried: Int) {
        let filter = deckFilterSQL(deckID: deckID)
        func count(_ whereSQL: String) throws -> Int {
            try db.scalarInt("SELECT COUNT(*) FROM cards c WHERE \(whereSQL) \(filter.clause)", bind: {
                self.bindDeckIDs($0, ids: filter.ids, startingAt: 1)
            })
        }
        return (
            try count("queue = 0"),
            try count("queue IN (1,3)"),
            try count("queue = 2"),
            try count("queue = -1"),
            try count("queue IN (-2,-3)")
        )
    }

    /// Cards added in the last N days (by note id timestamp).
    func cardsAddedLastDays(_ days: Int, deckID: Int64? = nil) throws -> [Int: Int] {
        var map: [Int: Int] = [:]
        let now = Int64(Date().timeIntervalSince1970)
        let filter = deckFilterSQL(deckID: deckID)
        for day in 0..<days {
            let end = now - Int64(day * 86400)
            let start = end - 86400
            let count: Int
            if filter.ids.isEmpty {
                count = try db.scalarInt("SELECT COUNT(*) FROM notes WHERE id >= ? AND id < ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, start * 1000)
                    SQLiteDatabase.bindInt64($0, 2, end * 1000)
                })
            } else {
                count = try db.scalarInt("""
                    SELECT COUNT(DISTINCT n.id) FROM notes n JOIN cards c ON c.nid = n.id
                    WHERE n.id >= ? AND n.id < ? \(filter.clause)
                """) { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, start * 1000)
                    SQLiteDatabase.bindInt64(stmt, 2, end * 1000)
                    self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 3)
                }
            }
            map[day] = count
        }
        return map
    }

    /// Reviews in the last 24h bucketed by hour of day (0…23).
    func reviewsByHour(deckID: Int64? = nil) throws -> [Int: Int] {
        var map: [Int: Int] = [:]
        for h in 0..<24 { map[h] = 0 }
        let start = Int64(Date().timeIntervalSince1970) - 86400
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT id FROM revlog WHERE id >= ?"
        } else {
            sql = "SELECT r.id FROM revlog r JOIN cards c ON c.id = r.cid WHERE r.id >= ? \(filter.clause)"
        }
        try db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start * 1000)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            let ms = sqlite3_column_int64(stmt, 0)
            let date = Date(timeIntervalSince1970: TimeInterval(ms / 1000))
            let hour = Calendar.current.component(.hour, from: date)
            map[hour, default: 0] += 1
        }
        return map
    }

    // MARK: - Mapping

    static func mapCard(_ stmt: OpaquePointer) -> AnkiCard {
        AnkiCard(
            id: sqlite3_column_int64(stmt, 0),
            nid: sqlite3_column_int64(stmt, 1),
            did: sqlite3_column_int64(stmt, 2),
            ord: Int(sqlite3_column_int(stmt, 3)),
            mod: sqlite3_column_int64(stmt, 4),
            usn: Int(sqlite3_column_int(stmt, 5)),
            type: Int(sqlite3_column_int(stmt, 6)),
            queue: Int(sqlite3_column_int(stmt, 7)),
            due: Int(sqlite3_column_int(stmt, 8)),
            ivl: Int(sqlite3_column_int(stmt, 9)),
            factor: Int(sqlite3_column_int(stmt, 10)),
            reps: Int(sqlite3_column_int(stmt, 11)),
            lapses: Int(sqlite3_column_int(stmt, 12)),
            left: Int(sqlite3_column_int(stmt, 13)),
            odue: Int(sqlite3_column_int(stmt, 14)),
            odid: sqlite3_column_int64(stmt, 15),
            flags: Int(sqlite3_column_int(stmt, 16)),
            data: SQLiteDatabase.text(stmt, 17)
        )
    }

    static func mapNote(_ stmt: OpaquePointer) -> AnkiNote {
        AnkiNote(
            id: sqlite3_column_int64(stmt, 0),
            guid: SQLiteDatabase.text(stmt, 1),
            mid: sqlite3_column_int64(stmt, 2),
            mod: sqlite3_column_int64(stmt, 3),
            usn: Int(sqlite3_column_int(stmt, 4)),
            tags: SQLiteDatabase.text(stmt, 5),
            flds: SQLiteDatabase.text(stmt, 6),
            sfld: SQLiteDatabase.text(stmt, 7),
            csum: sqlite3_column_int64(stmt, 8),
            flags: Int(sqlite3_column_int(stmt, 9)),
            data: SQLiteDatabase.text(stmt, 10)
        )
    }

    // MARK: - IDs / helpers

    func recentNoteSummaries(limit: Int = 20) -> [(id: Int64, title: String)] {
        var rows: [(id: Int64, title: String)] = []
        try? db.query("SELECT id, sfld FROM notes ORDER BY id DESC LIMIT \(max(limit, 1))") { stmt in
            let title = SQLiteDatabase.text(stmt, 1)
            rows.append((sqlite3_column_int64(stmt, 0), title.isEmpty ? "Nota sem texto" : title))
        }
        return rows
    }

    func timestampID() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func randomGUID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")
        return String((0..<10).map { _ in chars.randomElement()! })
    }

    func fieldChecksum(_ text: String) -> Int64 {
        // Anki uses first 8 hex digits of sha1 of stripped field
        let stripped = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let digest = SHA1.hash(stripped)
        let hex = digest.prefix(8)
        return Int64(hex, radix: 16) ?? 0
    }

    static func int64(_ any: Any?) -> Int64? {
        switch any {
        case let i as Int64: return i
        case let i as Int: return Int64(i)
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    static func int(_ any: Any?) -> Int? {
        if let i = int64(any) { return Int(i) }
        return nil
    }
}

enum ClozeHelper {
    static func ords(in fields: [String]) -> [Int] {
        var set = Set<Int>()
        let pattern = try! NSRegularExpression(pattern: #"\{\{c(\d+(?:,\d+)*)::"#)
        for field in fields {
            let range = NSRange(field.startIndex..., in: field)
            pattern.enumerateMatches(in: field, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: field) else { return }
                for part in field[r].split(separator: ",") {
                    if let n = Int(part) { set.insert(n - 1) }
                }
            }
        }
        return set.sorted()
    }
}

enum SHA1 {
    static func hash(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
