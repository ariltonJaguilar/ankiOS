import Foundation
import SQLite3

// Port of rslib's v3 study queue: deck limits (decks/limits.rs), deck tree counts
// (decks/tree.rs), the queue builder (scheduler/queue/builder) and the incremental
// card queues (scheduler/queue).

// MARK: - Daily limits

enum DeckLimitKind {
    case review
    case new
}

struct RemainingLimits: Equatable {
    var review: Int
    var new: Int
    var capNewToReview: Bool

    static let unlimited = RemainingLimits(review: 9999, new: 9999, capNewToReview: false)

    func get(_ kind: DeckLimitKind) -> Int {
        kind == .review ? review : new
    }

    mutating func cap(to other: RemainingLimits) {
        review = min(review, other.review)
        new = min(new, other.new)
    }

    /// True if some limit was decremented to 0.
    mutating func decrement(_ kind: DeckLimitKind) -> Bool {
        let before = self
        switch kind {
        case .review:
            review = max(0, review - 1)
            if capNewToReview { new = min(new, review) }
        case .new:
            new = max(0, new - 1)
        }
        return (before.review > 0 && review == 0) || (before.new > 0 && new == 0)
    }
}

/// rslib `DeckCommon` study counters, merged from the schema-11 `*Today` pairs.
struct DeckStudiedToday: Equatable {
    var day: Int
    var new: Int
    var review: Int
    var learning: Int
    var milliseconds: Int
}

extension AnkiDeck {
    var studiedToday: DeckStudiedToday {
        func pair(_ value: [Int]) -> (day: Int, amount: Int) {
            (value.first ?? 0, value.count > 1 ? value[1] : 0)
        }
        let new = pair(newToday)
        let review = pair(revToday)
        let learning = pair(lrnToday)
        let time = pair(timeToday)
        let day = max(time.day, new.day, review.day)
        return DeckStudiedToday(
            day: day,
            new: new.day == day ? new.amount : 0,
            review: review.day == day ? review.amount : 0,
            learning: learning.day == day ? learning.amount : 0,
            milliseconds: time.amount
        )
    }

    mutating func setStudiedToday(_ value: DeckStudiedToday) {
        newToday = [value.day, value.new]
        revToday = [value.day, value.review]
        lrnToday = [value.day, value.learning]
        timeToday = [value.day, value.milliseconds]
    }

    /// rslib `Deck::new_rev_counts`.
    func newReviewStudied(today: Int) -> (new: Int, review: Int) {
        let studied = studiedToday
        return studied.day == today ? (studied.new, studied.review) : (0, 0)
    }

    var nameLevel: Int { name.components(separatedBy: "::").count }
}

/// rslib `LimitTreeMap`: per-deck remaining limits, children capped to their parents.
struct DeckLimitTree {
    private struct Node {
        var level: Int
        var limits: RemainingLimits
        var parent: Int?
        var children: [Int] = []
    }

    private var nodes: [Node] = []
    private var nodeForDeck: [Int64: Int] = [:]

    /// `decks` must be sorted by name, starting with the top-most deck.
    init(decks: [AnkiDeck], limits: (AnkiDeck) -> RemainingLimits) {
        guard let root = decks.first else { return }
        nodes.append(Node(level: root.nameLevel, limits: limits(root), parent: nil))
        nodeForDeck[root.id] = 0
        var position = 1
        addChildren(of: 0, decks: decks, position: &position, limits: limits)
    }

    private mutating func addChildren(of parent: Int, decks: [AnkiDeck], position: inout Int, limits: (AnkiDeck) -> RemainingLimits) {
        let parentLevel = nodes[parent].level
        while position < decks.count {
            let deck = decks[position]
            let level = deck.nameLevel
            if level <= parentLevel { break }
            if level == parentLevel + 1 {
                var childLimits = limits(deck)
                childLimits.cap(to: nodes[parent].limits)
                nodes.append(Node(level: level, limits: childLimits, parent: parent))
                let node = nodes.count - 1
                nodes[parent].children.append(node)
                nodeForDeck[deck.id] = node
                position += 1
            } else if let last = nodes[parent].children.last {
                addChildren(of: last, decks: decks, position: &position, limits: limits)
            } else {
                position += 1
            }
        }
    }

    func rootLimitReached(_ kind: DeckLimitKind) -> Bool {
        (nodes.first?.limits.get(kind) ?? 0) == 0
    }

    func limitReached(_ deckID: Int64, _ kind: DeckLimitKind) -> Bool {
        guard let node = nodeForDeck[deckID] else { return true }
        return nodes[node].limits.get(kind) == 0
    }

    mutating func decrementDeckAndParents(_ deckID: Int64, _ kind: DeckLimitKind) {
        var current = nodeForDeck[deckID]
        while let node = current {
            if nodes[node].limits.decrement(kind) {
                capNodeAndDescendants(node, to: nodes[node].limits)
            }
            current = nodes[node].parent
        }
    }

    private mutating func capNodeAndDescendants(_ node: Int, to limits: RemainingLimits) {
        nodes[node].limits.cap(to: limits)
        for child in nodes[node].children {
            capNodeAndDescendants(child, to: limits)
        }
    }
}

// MARK: - Card queues

/// rslib `CardQueues`: built once per deck, then updated as cards are answered.
final class StudyQueues {
    struct Counts: Equatable {
        var new = 0
        var learning = 0
        var review = 0

        var isZero: Bool { new == 0 && learning == 0 && review == 0 }
    }

    enum MainKind: Equatable {
        case new
        case review
        case interdayLearning
    }

    struct MainEntry: Equatable {
        var id: Int64
        var mtime: Int64
        var kind: MainKind
    }

    struct LearningEntry: Equatable {
        var due: Int64
        var id: Int64
        var mtime: Int64
        var reps: Int

        static func order(_ a: LearningEntry, _ b: LearningEntry) -> ComparisonResult {
            let aNew = a.reps == 0, bNew = b.reps == 0
            if aNew != bNew { return aNew ? .orderedDescending : .orderedAscending }
            if a.due != b.due { return a.due < b.due ? .orderedAscending : .orderedDescending }
            return .orderedSame
        }
    }

    enum Entry: Equatable {
        case intradayLearning(LearningEntry)
        case main(MainEntry)

        var cardID: Int64 {
            switch self {
            case .intradayLearning(let e): e.id
            case .main(let e): e.id
            }
        }

        var mtime: Int64 {
            switch self {
            case .intradayLearning(let e): e.mtime
            case .main(let e): e.mtime
            }
        }
    }

    struct CutoffSnapshot: Equatable {
        var learningCount: Int
        var learningCutoff: Int64
    }

    /// rslib `QueueUpdate`, kept with the answer's undo entry.
    struct Update: Equatable {
        var entry: Entry
        var learningRequeue: LearningEntry?
        var queueBuildTime: Int64
        var cutoffSnapshot: CutoffSnapshot
    }

    let deckID: Int64
    let currentDay: Int
    let learnAheadSecs: Int64
    let buildTime: Int64
    private(set) var counts: Counts
    private(set) var main: [MainEntry]
    private(set) var intradayLearning: [LearningEntry]
    private(set) var currentLearningCutoff: Int64
    /// Store change counter this queue reflects; any other change triggers a rebuild.
    var changeToken: Int

    init(deckID: Int64, currentDay: Int, learnAheadSecs: Int64, buildTime: Int64, counts: Counts,
         main: [MainEntry], intradayLearning: [LearningEntry], currentLearningCutoff: Int64, changeToken: Int) {
        self.deckID = deckID
        self.currentDay = currentDay
        self.learnAheadSecs = learnAheadSecs
        self.buildTime = buildTime
        self.counts = counts
        self.main = main
        self.intradayLearning = intradayLearning
        self.currentLearningCutoff = currentLearningCutoff
        self.changeToken = changeToken
    }

    private var learnAheadCutoff: Int64 { currentLearningCutoff + learnAheadSecs }

    /// Cards in study order: learning due now, the main queue, then learning due within learn-ahead.
    var entries: [Entry] {
        let cutoff = currentLearningCutoff
        let ahead = learnAheadCutoff
        return intradayLearning.filter { $0.due <= cutoff }.map(Entry.intradayLearning)
            + main.map(Entry.main)
            + intradayLearning.filter { $0.due > cutoff && $0.due <= ahead }.map(Entry.intradayLearning)
    }

    var top: Entry? { entries.first }

    /// rslib `CardQueues::counts`.
    func currentCounts(now: Int64) -> Counts {
        if counts.isZero { _ = updateLearningCutoffAndCount(now: now) }
        return counts
    }

    func popEntry(_ id: Int64) -> Entry? {
        if let index = intradayLearning.firstIndex(where: { $0.id == id }) {
            let entry = intradayLearning.remove(at: index)
            counts.learning = max(0, counts.learning - 1)
            return .intradayLearning(entry)
        }
        if let head = main.first, head.id == id {
            return .main(popMain())
        }
        return nil
    }

    private func popMain() -> MainEntry {
        let head = main.removeFirst()
        switch head.kind {
        case .new: counts.new -= 1
        case .review: counts.review -= 1
        case .interdayLearning: counts.learning = max(0, counts.learning - 1)
        }
        return head
    }

    private func pushMain(_ entry: MainEntry) {
        switch entry.kind {
        case .new: counts.new += 1
        case .review: counts.review += 1
        case .interdayLearning: counts.learning += 1
        }
        main.insert(entry, at: 0)
    }

    private func pushUndoEntry(_ entry: Entry) {
        switch entry {
        case .intradayLearning(let e):
            intradayLearning.insert(e, at: 0)
            counts.learning += 1
        case .main(let e):
            pushMain(e)
        }
    }

    @discardableResult
    func updateLearningCutoffAndCount(now: Int64) -> CutoffSnapshot {
        let change = CutoffSnapshot(learningCount: counts.learning, learningCutoff: currentLearningCutoff)
        let lastAhead = learnAheadCutoff
        currentLearningCutoff = now
        let newAhead = learnAheadCutoff
        counts.learning += intradayLearning.filter { $0.due > lastAhead && $0.due <= newAhead }.count
        return change
    }

    private func restoreCutoff(_ snapshot: CutoffSnapshot) {
        counts.learning = snapshot.learningCount
        currentLearningCutoff = snapshot.learningCutoff
    }

    func maybeRequeueLearningCard(_ card: AnkiCard, nextDayAt: Int64) -> LearningEntry? {
        guard card.queue == AnkiCard.Queue.learning.rawValue || card.queue == AnkiCard.Queue.preview.rawValue,
              Int64(card.due) < nextDayAt else { return nil }
        return requeueLearningEntry(LearningEntry(due: Int64(card.due), id: card.id, mtime: card.mod, reps: card.reps))
    }

    private func requeueLearningEntry(_ input: LearningEntry) -> LearningEntry {
        var entry = input
        let cutoff = learnAheadCutoff
        if entry.due <= cutoff && main.isEmpty, let next = intradayLearning.first {
            if next.due >= entry.due && next.due + 1 < cutoff {
                entry.due = next.due + 1
            }
        }
        insertIntradayLearningCard(entry)
        return entry
    }

    private func insertIntradayLearningCard(_ entry: LearningEntry) {
        if entry.due <= learnAheadCutoff {
            counts.learning += 1
        }
        intradayLearning.insert(entry, at: Self.binarySearchIndex(intradayLearning, entry))
    }

    /// Rust `slice::binary_search_by(...).unwrap_or_else(|e| e)`.
    private static func binarySearchIndex(_ items: [LearningEntry], _ entry: LearningEntry) -> Int {
        var size = items.count
        if size == 0 { return 0 }
        var base = 0
        while size > 1 {
            let half = size / 2
            let mid = base + half
            if LearningEntry.order(items[mid], entry) != .orderedDescending { base = mid }
            size -= half
        }
        switch LearningEntry.order(items[base], entry) {
        case .orderedSame: return base
        case .orderedAscending: return base + 1
        case .orderedDescending: return base
        }
    }

    private func removeIntradayLearningCard(_ id: Int64) {
        guard let index = intradayLearning.firstIndex(where: { $0.id == id }) else { return }
        let entry = intradayLearning.remove(at: index)
        if entry.due <= learnAheadCutoff {
            counts.learning = max(0, counts.learning - 1)
        }
    }

    /// rslib `update_queues_after_answering_card`.
    func applyAnswer(card: AnkiCard, nextDayAt: Int64, finishedPreview: Bool, now: Int64) -> Update? {
        guard let entry = popEntry(card.id) else { return nil }
        let requeued = finishedPreview ? nil : maybeRequeueLearningCard(card, nextDayAt: nextDayAt)
        let snapshot = updateLearningCutoffAndCount(now: now)
        return Update(entry: entry, learningRequeue: requeued, queueBuildTime: buildTime, cutoffSnapshot: snapshot)
    }

    /// rslib `undo_queue_change(CardAnswered)`.
    func undoAnswer(_ update: Update) {
        restoreCutoff(update.cutoffSnapshot)
        if let learning = update.learningRequeue {
            removeIntradayLearningCard(learning.id)
        }
        pushUndoEntry(update.entry)
    }

    /// rslib `undo_queue_change(CardAnswerUndone)`.
    func redoAnswer(_ update: Update) {
        _ = popEntry(update.entry.cardID)
        if let learning = update.learningRequeue {
            insertIntradayLearningCard(learning)
        }
        restoreCutoff(update.cutoffSnapshot)
    }
}

// MARK: - Queue builder

private struct QueueSortOptions {
    var newOrder = 1          // NewCardSortOrder
    var newGatherPriority = 0 // NewCardGatherPriority
    var reviewOrder = 0       // ReviewCardOrder
    var dayLearnMix = 0       // ReviewMix
    var newReviewMix = 0      // ReviewMix
}

private struct BuryMode {
    var buryNew = false
    var buryReviews = false
    var buryInterdayLearning = false
}

private struct DueCard {
    var id: Int64
    var nid: Int64
    var due: Int
    var mtime: Int64
    var did: Int64
    var odid: Int64
    var reps: Int
}

private struct NewCard {
    var id: Int64
    var nid: Int64
    var ord: Int
    var mtime: Int64
    var did: Int64
    var odid: Int64
    var hash: UInt64 = 0
}

/// rslib `Intersperser`.
private func intersperse<T>(_ one: [T], _ two: [T]) -> [T] {
    let ratio = Float(one.count + 1) / Float(two.count + 1)
    var result: [T] = []
    result.reserveCapacity(one.count + two.count)
    var i = 0
    var j = 0
    while i < one.count || j < two.count {
        if i < one.count, j < two.count {
            if Float(j + 1) * ratio < Float(i + 1) {
                result.append(two[j]); j += 1
            } else {
                result.append(one[i]); i += 1
            }
        } else if i < one.count {
            result.append(one[i]); i += 1
        } else {
            result.append(two[j]); j += 1
        }
    }
    return result
}

private func mix<T>(_ first: [T], _ second: [T], mode: Int, firstIsReviews _: Bool) -> [T] {
    // ReviewMix: 0 mix with reviews, 1 after reviews, 2 before reviews
    switch mode {
    case 1: return first + second
    case 2: return second + first
    default: return intersperse(first, second)
    }
}

extension CollectionStore {
    var learnAheadSecs: Int { Self.int(conf["collapseTime"]) ?? 1200 }
    var newCardsIgnoreReviewLimit: Bool { conf["newCardsIgnoreReviewLimit"] as? Bool ?? false }
    var applyAllParentLimits: Bool { conf["applyAllParentLimits"] as? Bool ?? false }
    var fsrsEnabled: Bool { conf["fsrs"] as? Bool ?? false }

    /// rslib `RemainingLimits::new`.
    func remainingLimits(for deck: AnkiDeck, today: Int) -> RemainingLimits {
        guard !deck.isFiltered, let config = deckConfigs.first(where: { $0.id == deck.conf }) else {
            return .unlimited
        }
        func current(_ todayLimit: AnkiDayLimit?, _ limit: Int?) -> Int? {
            if let todayLimit, todayLimit.today == today { return todayLimit.limit }
            return limit
        }
        var reviewLimit = current(deck.reviewLimitToday, deck.reviewLimit) ?? config.rev.perDay
        var newLimit = current(deck.newLimitToday, deck.newLimit) ?? config.new.perDay
        let studied = deck.newReviewStudied(today: today)
        reviewLimit -= studied.review
        newLimit -= studied.new
        let ignoreReviewLimit = newCardsIgnoreReviewLimit
        if !ignoreReviewLimit {
            reviewLimit -= studied.new
            newLimit = min(newLimit, reviewLimit)
        }
        return RemainingLimits(review: max(0, reviewLimit), new: max(0, newLimit), capNewToReview: !ignoreReviewLimit)
    }

    /// Anki sorts decks by their native name (`\x1f` separated) with the `unicase` collation.
    static func deckNameOrder(_ a: String, _ b: String) -> Bool {
        let left = a.replacingOccurrences(of: "::", with: "\u{1f}").lowercased()
        let right = b.replacingOccurrences(of: "::", with: "\u{1f}").lowercased()
        return left.unicodeScalars.lexicographicallyPrecedes(right.unicodeScalars)
    }

    func childDecks(of deck: AnkiDeck) -> [AnkiDeck] {
        let prefix = deck.name.lowercased() + "::"
        return decks.filter { $0.name.lowercased().hasPrefix(prefix) }
            .sorted { Self.deckNameOrder($0.name, $1.name) }
    }

    /// Immediate parent first, like rslib `parent_decks`.
    func parentDecks(of deck: AnkiDeck) -> [AnkiDeck] {
        var parents: [AnkiDeck] = []
        var parts = deck.name.components(separatedBy: "::")
        while parts.count > 1 {
            parts.removeLast()
            let name = parts.joined(separator: "::").lowercased()
            guard let parent = decks.first(where: { $0.name.lowercased() == name }) else { break }
            parents.append(parent)
        }
        return parents
    }

    // MARK: Deck tree counts

    /// rslib `deck_tree(Some(now))` counts: per-deck due counts with limits applied up the tree.
    func deckTreeCounts(at now: Date = Date()) throws -> [Int64: DeckCounts] {
        struct Own { var new = 0, review = 0, interday = 0, intraday = 0 }
        struct NodeCounts {
            var new = 0, review = 0, intraday = 0, interday = 0
            mutating func add(_ other: NodeCounts) {
                new += other.new
                review += other.review
                intraday += other.intraday
                interday += other.interday
            }
            func capped(_ remaining: RemainingLimits) -> NodeCounts {
                var c = self
                c.interday = min(c.interday, remaining.review)
                var remainingReviews = max(0, remaining.review - c.interday)
                c.review = min(c.review, remainingReviews)
                c.new = min(c.new, remaining.new)
                if remaining.capNewToReview {
                    remainingReviews = max(0, remainingReviews - c.review)
                    c.new = min(c.new, remainingReviews)
                }
                return c
            }
        }

        let timing = Self.schedTiming(creation: collectionCreation(), configuration: conf, at: now)
        let today = timing.daysElapsed
        let learnCutoff = Int64(UInt32(truncatingIfNeeded: Int64(now.timeIntervalSince1970)) &+ UInt32(truncatingIfNeeded: learnAheadSecs))
        var own: [Int64: Own] = [:]
        try db.query("""
            SELECT did, sum(queue = 0), sum(queue = 2 AND due <= ?1), sum(queue = 3 AND due <= ?1),
            sum((queue = 1 AND due < ?2) OR (queue = 4 AND due <= ?2))
            FROM cards GROUP BY did
        """, bind: { stmt in
            SQLiteDatabase.bindInt(stmt, 1, today)
            SQLiteDatabase.bindInt64(stmt, 2, learnCutoff)
        }) { stmt in
            own[sqlite3_column_int64(stmt, 0)] = Own(
                new: Int(sqlite3_column_int64(stmt, 1)),
                review: Int(sqlite3_column_int64(stmt, 2)),
                interday: Int(sqlite3_column_int64(stmt, 3)),
                intraday: Int(sqlite3_column_int64(stmt, 4))
            )
        }

        let sorted = decks.sorted { Self.deckNameOrder($0.name, $1.name) }
        var children: [Int64: [Int64]] = [:]
        var position = 0
        func addChildren(of parent: Int64, level: Int) {
            while position < sorted.count {
                let deck = sorted[position]
                let deckLevel = deck.nameLevel
                if deckLevel <= level { break }
                if deckLevel == level + 1 {
                    children[parent, default: []].append(deck.id)
                    position += 1
                } else if let last = children[parent]?.last {
                    addChildren(of: last, level: level + 1)
                } else {
                    position += 1
                }
            }
        }
        addChildren(of: 0, level: 0)

        let limits = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, remainingLimits(for: $0, today: today)) })
        var result: [Int64: DeckCounts] = [:]
        func sum(_ deckID: Int64, parentLimits: RemainingLimits?) -> NodeCounts {
            var remaining = limits[deckID] ?? .unlimited
            var passed = parentLimits
            if let parentLimits {
                remaining.cap(to: parentLimits)
                passed = remaining
            }
            let mine = own[deckID] ?? Own()
            var uncapped = NodeCounts(new: mine.new, review: mine.review, intraday: mine.intraday, interday: mine.interday)
            for child in children[deckID] ?? [] {
                uncapped.add(sum(child, parentLimits: passed))
            }
            let capped = uncapped.capped(remaining)
            if deckID != 0 {
                result[deckID] = DeckCounts(new: capped.new, learn: capped.intraday + capped.interday, review: capped.review)
            }
            return capped
        }
        _ = sum(0, parentLimits: applyAllParentLimits ? .unlimited : nil)
        return result
    }

    // MARK: Building

    private func sortOptions(for deck: AnkiDeck) -> QueueSortOptions {
        guard !deck.isFiltered, let config = deckConfigs.first(where: { $0.id == deck.conf }) else {
            return QueueSortOptions()
        }
        return QueueSortOptions(
            newOrder: config.newSortOrder,
            newGatherPriority: config.newGatherPriority,
            reviewOrder: config.reviewOrder,
            dayLearnMix: config.interdayLearningMix,
            newReviewMix: config.newMix
        )
    }

    private func buryMode(forHomeDeck deckID: Int64) -> BuryMode {
        guard let deck = deck(id: deckID), !deck.isFiltered,
              let config = deckConfigs.first(where: { $0.id == deck.conf }) else { return BuryMode() }
        return BuryMode(buryNew: config.new.bury, buryReviews: config.rev.bury, buryInterdayLearning: config.buryInterdayLearning)
    }

    private func reviewOrderSQL(_ order: Int, today: Int, nextDayAt: Int64, now: Int64) -> String {
        let fsrs = fsrsEnabled
        var clauses: [String]
        switch order {
        case 1: clauses = ["due", "(select rowid from active_decks ad where ad.id = did)"]
        case 2: clauses = ["(select rowid from active_decks ad where ad.id = did)", "due"]
        case 3: clauses = ["ivl asc"]
        case 4: clauses = ["ivl desc"]
        case 5: clauses = [fsrs ? "extract_fsrs_variable(data, 'd') desc" : "factor asc"]
        case 6: clauses = [fsrs ? "extract_fsrs_variable(data, 'd') asc" : "factor desc"]
        case 7, 11:
            clauses = ["extract_fsrs_retrievability(data, case when odue !=0 then odue else due end, ivl, \(today), \(nextDayAt), \(now)) \(order == 7 ? "asc" : "desc")"]
        case 12:
            clauses = [fsrs
                ? "extract_fsrs_relative_retrievability(data, case when odue !=0 then odue else due end, ivl, \(today), \(nextDayAt), \(now)) asc"
                : "-(1 + cast(\(today)-due+0.001 as real)/ivl) asc"]
        case 8: clauses = []
        case 9: clauses = ["nid asc, ord asc"]
        case 10: clauses = ["nid desc, ord asc"]
        default: clauses = ["due"]
        }
        clauses.append("fnvhash(id, mod)")
        return clauses.joined(separator: ", ")
    }

    private func updateActiveDecks(_ activeIDs: [Int64]) throws {
        try db.exec("DROP TABLE IF EXISTS temp.active_decks; CREATE TEMPORARY TABLE active_decks (id integer not null unique);")
        for id in activeIDs {
            try db.run("INSERT INTO active_decks VALUES (?)") { SQLiteDatabase.bindInt64($0, 1, id) }
        }
    }

    /// rslib `build_queues`.
    func buildStudyQueues(for deckID: Int64, now: Date = Date()) throws -> StudyQueues {
        guard let root = deck(id: deckID) else { throw SQLiteError.exec("Baralho não encontrado.") }
        let timing = Self.schedTiming(creation: collectionCreation(), configuration: conf, at: now)
        let today = timing.daysElapsed
        let nowSecs = Int64(now.timeIntervalSince1970)

        let children = childDecks(of: root)
        var limitDecks = [root] + children
        if applyAllParentLimits {
            for parent in parentDecks(of: root) { limitDecks.insert(parent, at: 0) }
        }
        var limits = DeckLimitTree(decks: limitDecks) { remainingLimits(for: $0, today: today) }
        let options = sortOptions(for: root)
        let activeIDs = [root.id] + children.map(\.id)
        try updateActiveDecks(activeIDs)

        var seenNotes: [Int64: BuryMode] = [:]
        func previousBuryMode(nid: Int64, homeDeck: Int64) -> BuryMode? {
            let mode = buryMode(forHomeDeck: homeDeck)
            if var existing = seenNotes[nid] {
                let previous = existing
                existing.buryNew = existing.buryNew || mode.buryNew
                existing.buryReviews = existing.buryReviews || mode.buryReviews
                existing.buryInterdayLearning = existing.buryInterdayLearning || mode.buryInterdayLearning
                seenNotes[nid] = existing
                return previous
            }
            seenNotes[nid] = mode
            return nil
        }
        func dueCard(_ stmt: OpaquePointer) -> DueCard {
            DueCard(
                id: sqlite3_column_int64(stmt, 0), nid: sqlite3_column_int64(stmt, 1),
                due: Int(sqlite3_column_int64(stmt, 2)), mtime: sqlite3_column_int64(stmt, 3),
                did: sqlite3_column_int64(stmt, 4), odid: sqlite3_column_int64(stmt, 5),
                reps: Int(sqlite3_column_int64(stmt, 6))
            )
        }

        // intraday learning
        var learning: [DueCard] = []
        try db.query("""
            SELECT id, nid, due, cast(mod AS integer), did, odid, reps FROM cards
            WHERE did IN (SELECT id FROM active_decks) AND (queue IN (1, 4) AND due <= ?)
        """, bind: { SQLiteDatabase.bindInt64($0, 1, timing.nextDayAt) }) { stmt in
            let card = dueCard(stmt)
            _ = previousBuryMode(nid: card.nid, homeDeck: card.odid != 0 ? card.odid : card.did)
            learning.append(card)
        }

        // interday learning, then reviews
        var dayLearning: [DueCard] = []
        var reviews: [DueCard] = []
        let orderSQL = reviewOrderSQL(options.reviewOrder, today: today, nextDayAt: timing.nextDayAt, now: nowSecs)
        for queue in [3, 2] where !limits.rootLimitReached(.review) {
            try db.forEachRow("""
                SELECT id, nid, due, cast(mod AS integer), did, odid, reps FROM cards
                WHERE did IN (SELECT id FROM active_decks) AND (queue = ? AND due <= ?)
                ORDER BY \(orderSQL)
            """, bind: { stmt in
                SQLiteDatabase.bindInt(stmt, 1, queue)
                SQLiteDatabase.bindInt(stmt, 2, today)
            }) { stmt in
                if limits.rootLimitReached(.review) { return false }
                let card = dueCard(stmt)
                if !limits.limitReached(card.did, .review) {
                    let buried = previousBuryMode(nid: card.nid, homeDeck: card.odid != 0 ? card.odid : card.did)
                        .map { queue == 2 ? $0.buryReviews : $0.buryInterdayLearning } ?? false
                    if !buried {
                        if queue == 2 { reviews.append(card) } else { dayLearning.append(card) }
                        limits.decrementDeckAndParents(card.did, .review)
                    }
                }
                return true
            }
        }

        // new cards
        var newCards: [NewCard] = []
        func newCard(_ stmt: OpaquePointer) -> NewCard {
            NewCard(
                id: sqlite3_column_int64(stmt, 0), nid: sqlite3_column_int64(stmt, 1),
                ord: Int(sqlite3_column_int64(stmt, 2)), mtime: sqlite3_column_int64(stmt, 3),
                did: sqlite3_column_int64(stmt, 4), odid: sqlite3_column_int64(stmt, 5)
            )
        }
        func addNew(_ card: NewCard) -> Bool {
            let buried = previousBuryMode(nid: card.nid, homeDeck: card.odid != 0 ? card.odid : card.did)?.buryNew ?? false
            if buried { return false }
            newCards.append(card)
            return true
        }
        let salt = Int64(UInt32(truncatingIfNeeded: today) &* 2_654_435_761)
        let newColumns = "SELECT id, nid, ord, cast(mod AS integer), did, odid FROM cards"
        func sortSQL(_ gather: Int) -> String {
            switch gather {
            case 2: "due DESC, ord ASC"
            case 3, 5: "fnvhash(nid, \(salt)), ord ASC"
            case 4: "fnvhash(id, \(salt))"
            default: "due ASC, ord ASC"
            }
        }
        switch options.newGatherPriority {
        case 0, 5:
            let order = sortSQL(options.newGatherPriority == 5 ? 5 : 1)
            for did in activeIDs.sorted(by: { a, b in
                Self.deckNameOrder(deck(id: a)?.name ?? "", deck(id: b)?.name ?? "")
            }) {
                if limits.rootLimitReached(.new) { break }
                if limits.limitReached(did, .new) { continue }
                try db.forEachRow("\(newColumns) WHERE did = ? AND queue = 0 ORDER BY \(order)", bind: {
                    SQLiteDatabase.bindInt64($0, 1, did)
                }) { stmt in
                    let reached = limits.limitReached(did, .new)
                    if !reached && addNew(newCard(stmt)) {
                        limits.decrementDeckAndParents(did, .new)
                    }
                    return !reached
                }
            }
        default:
            try db.forEachRow(
                "\(newColumns) WHERE did IN (SELECT id FROM active_decks) AND queue = 0 ORDER BY \(sortSQL(options.newGatherPriority))"
            ) { stmt in
                if limits.rootLimitReached(.new) { return false }
                let card = newCard(stmt)
                if !limits.limitReached(card.did, .new) && addNew(card) {
                    limits.decrementDeckAndParents(card.did, .new)
                }
                return true
            }
        }

        // sort new cards (NewCardSortOrder)
        func hashed(_ value: Int64) -> UInt64 { UInt64(bitPattern: SQLiteHash.fnv([value, Int64(today)])) }
        switch options.newOrder {
        case 0:
            newCards = newCards.enumerated()
                .sorted { $0.element.ord != $1.element.ord ? $0.element.ord < $1.element.ord : $0.offset < $1.offset }
                .map(\.element)
        case 2:
            for i in newCards.indices { newCards[i].hash = hashed(newCards[i].id) }
            newCards.sort { ($0.ord, $0.hash) < ($1.ord, $1.hash) }
        case 3:
            for i in newCards.indices { newCards[i].hash = hashed(newCards[i].nid) }
            newCards.sort { ($0.hash, $0.ord) < ($1.hash, $1.ord) }
        case 4:
            for i in newCards.indices { newCards[i].hash = hashed(newCards[i].id) }
            newCards.sort { $0.hash < $1.hash }
        default:
            break
        }

        let intraday = learning
            .map { StudyQueues.LearningEntry(due: Int64($0.due), id: $0.id, mtime: $0.mtime, reps: $0.reps) }
            .enumerated()
            .sorted { a, b in
                let order = StudyQueues.LearningEntry.order(a.element, b.element)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }
            .map(\.element)
        let cutoff = nowSecs + Int64(learnAheadSecs)
        var counts = StudyQueues.Counts()
        counts.learning = intraday.filter { $0.due <= cutoff }.count + dayLearning.count
        counts.review = reviews.count
        counts.new = newCards.count

        let reviewEntries = reviews.map { StudyQueues.MainEntry(id: $0.id, mtime: $0.mtime, kind: .review) }
        let dayLearnEntries = dayLearning.map { StudyQueues.MainEntry(id: $0.id, mtime: $0.mtime, kind: .interdayLearning) }
        let newEntries = newCards.map { StudyQueues.MainEntry(id: $0.id, mtime: $0.mtime, kind: .new) }
        let withInterday = mix(reviewEntries, dayLearnEntries, mode: options.dayLearnMix, firstIsReviews: true)
        let main = mix(withInterday, newEntries, mode: options.newReviewMix, firstIsReviews: true)

        return StudyQueues(
            deckID: deckID,
            currentDay: today,
            learnAheadSecs: Int64(learnAheadSecs),
            buildTime: Int64(Date().timeIntervalSince1970 * 1000),
            counts: counts,
            main: main,
            intradayLearning: intraday,
            currentLearningCutoff: nowSecs,
            changeToken: -1
        )
    }

    // MARK: Cached queues

    /// Counter bumped by temporary triggers whenever cards (except flag-only edits), decks or
    /// presets change, mirroring rslib `requires_study_queue_rebuild`.
    func studyChangeToken() throws -> Int {
        var token: Int?
        do {
            try db.query("SELECT n FROM temp.ankios_study_changes") { token = Int(sqlite3_column_int64($0, 0)) }
        } catch {
            try db.exec("""
                CREATE TEMP TABLE IF NOT EXISTS ankios_study_changes (n INTEGER NOT NULL);
                DELETE FROM temp.ankios_study_changes;
                INSERT INTO temp.ankios_study_changes VALUES (0);
                CREATE TEMP TRIGGER IF NOT EXISTS ankios_cards_insert AFTER INSERT ON main.cards
                BEGIN UPDATE ankios_study_changes SET n = n + 1; END;
                CREATE TEMP TRIGGER IF NOT EXISTS ankios_cards_delete AFTER DELETE ON main.cards
                BEGIN UPDATE ankios_study_changes SET n = n + 1; END;
                CREATE TEMP TRIGGER IF NOT EXISTS ankios_cards_update AFTER UPDATE ON main.cards
                WHEN NEW.nid IS NOT OLD.nid OR NEW.did IS NOT OLD.did OR NEW.ord IS NOT OLD.ord
                  OR NEW.type IS NOT OLD.type OR NEW.queue IS NOT OLD.queue OR NEW.due IS NOT OLD.due
                  OR NEW.ivl IS NOT OLD.ivl OR NEW.factor IS NOT OLD.factor OR NEW.reps IS NOT OLD.reps
                  OR NEW.lapses IS NOT OLD.lapses OR NEW.left IS NOT OLD.left OR NEW.odue IS NOT OLD.odue
                  OR NEW.odid IS NOT OLD.odid OR NEW.data IS NOT OLD.data
                BEGIN UPDATE ankios_study_changes SET n = n + 1; END;
                CREATE TEMP TRIGGER IF NOT EXISTS ankios_col_update AFTER UPDATE OF decks, dconf ON main.col
                WHEN NEW.decks IS NOT OLD.decks OR NEW.dconf IS NOT OLD.dconf
                BEGIN UPDATE ankios_study_changes SET n = n + 1; END;
            """)
            token = 0
        }
        return token ?? 0
    }

    /// rslib `get_queues`: the cached queues for `deckID`, rebuilt when stale. A new day also
    /// unburies cards, as `clear_queues_if_day_changed` does.
    func studyQueues(for deckID: Int64) throws -> StudyQueues {
        let today = schedDay()
        if let cached = studyQueueCache, cached.currentDay != today {
            studyQueueCache = nil
            try unburySiblingCardsIfNewDay()
        }
        let token = try studyChangeToken()
        if let cached = studyQueueCache, cached.deckID == deckID, cached.changeToken == token {
            return cached
        }
        let queues = try buildStudyQueues(for: deckID)
        queues.changeToken = try studyChangeToken()
        studyQueueCache = queues
        return queues
    }

    /// rslib `get_queued_cards`: the next cards in study order plus the queue counts.
    func queuedStudyCards(for deckID: Int64, limit: Int = 1) throws -> (cards: [AnkiCard], counts: StudyQueues.Counts) {
        for attempt in 0..<2 {
            let queues = try studyQueues(for: deckID)
            let counts = queues.currentCounts(now: Int64(Date().timeIntervalSince1970))
            var cards: [AnkiCard] = []
            var consistent = true
            for entry in queues.entries.prefix(limit) {
                guard let card = try fetchCard(id: entry.cardID), card.mod == entry.mtime else {
                    consistent = false
                    break
                }
                cards.append(card)
            }
            if consistent || attempt == 1 {
                return (cards, counts)
            }
            studyQueueCache = nil
        }
        return ([], StudyQueues.Counts())
    }

    /// The next card for `deckID` without replacing the study session's cached queues.
    func peekStudyCard(for deckID: Int64) throws -> AnkiCard? {
        if let cached = studyQueueCache, cached.deckID == deckID, cached.currentDay == schedDay(),
           cached.changeToken == (try studyChangeToken()) {
            return try queuedStudyCards(for: deckID).cards.first
        }
        guard let top = try buildStudyQueues(for: deckID).top else { return nil }
        return try fetchCard(id: top.cardID)
    }

    /// The cached queues, if nothing changed them since they were last synced. Call before an
    /// answer, undo or redo writes to the collection.
    func studyQueuesForUpdate() -> StudyQueues? {
        guard let cached = studyQueueCache,
              cached.currentDay == schedDay(),
              let token = try? studyChangeToken(),
              cached.changeToken == token else {
            studyQueueCache = nil
            return nil
        }
        return cached
    }

    /// Accept the collection writes of an answer, undo or redo the queues were updated for.
    func finishStudyQueueUpdate(_ queues: StudyQueues?) {
        guard let queues, studyQueueCache === queues, let token = try? studyChangeToken() else {
            studyQueueCache = nil
            return
        }
        queues.changeToken = token
    }

    func discardStudyQueues() {
        studyQueueCache = nil
    }

    var studyNextDayAt: Int64 {
        Self.schedTiming(creation: collectionCreation(), configuration: conf, at: Date()).nextDayAt
    }
}
