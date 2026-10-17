import Foundation
import SQLite3

/// Helpers for rebuilding filtered decks from stored search terms.
enum FilteredDeckSupport {
    /// Anki starts filtered positions at -100_000 so they sort as already due.
    static let orderOrigin = -100_000
    /// Custom study preview delays: Again 1 min, Hard 10 min, Good returns the card.
    static let previewAgainSeconds = 60
    static let previewHardSeconds = 600
    static let previewGoodSeconds = 0

    /// Anki always excludes suspended, buried and cards already in a filtered deck.
    static func gatherSearch(_ search: String) -> String {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let exclusion = "-is:suspended -is:buried -deck:filtered"
        return trimmed.isEmpty ? exclusion : "(\(trimmed)) \(exclusion)"
    }

    @MainActor
    @discardableResult
    static func rebuild(_ deck: AnkiDeck, store: CollectionStore, shuffle: Bool = false) throws -> Int {
        guard deck.isFiltered, deck.searchTerms != nil else { return 0 }
        try returnHome(deckID: deck.id, store: store)
        let ids = try selectedCardIDs(deck, store: store, shuffle: shuffle)
        try install(cardIDs: ids, deckID: deck.id, reschedule: deck.resched ?? true, store: store)
        try store.refreshCounts()
        return ids.count
    }

    @MainActor
    static func selectedCardIDs(_ deck: AnkiDeck, store: CollectionStore, shuffle: Bool = false) throws -> [Int64] {
        guard deck.isFiltered, let search = deck.searchTerms else { return [] }
        let today = store.schedDay()
        let now = Int(Date().timeIntervalSince1970)
        var ids = try gatherIDs(search, limit: deck.termLimit ?? 50, order: deck.searchOrder ?? "", deck: deck, store: store, today: today, now: now, shuffle: shuffle)
        if let second = deck.searchTerms2 {
            let more = try gatherIDs(
                second,
                limit: deck.termLimit2 ?? 50,
                order: deck.searchOrder2 ?? deck.searchOrder ?? "",
                deck: deck,
                store: store,
                today: today,
                now: now,
                shuffle: shuffle
            )
            let seen = Set(ids)
            ids.append(contentsOf: more.filter { !seen.contains($0) })
        }
        return ids
    }

    @MainActor
    private static func gatherIDs(
        _ search: String,
        limit: Int,
        order: String,
        deck: AnkiDeck,
        store: CollectionStore,
        today: Int,
        now: Int,
        shuffle: Bool
    ) throws -> [Int64] {
        let fetchLimit = Int.max
        var rows = try store.search(query: gatherSearch(search), limit: fetchLimit)
        rows = applyTagFilter(rows, include: deck.includeTags, exclude: deck.excludeTags)
        let lastSeen = order == "oldest" ? try lastReviewTimestamps(for: rows, store: store) : [:]
        let fsrs = store.fsrsEnabled
        sortForGather(&rows, order: order, today: today, now: now, shuffle: shuffle, lastSeen: lastSeen, fsrs: fsrs)
        return rows.prefix(max(limit, 0)).map(\.card.id)
    }

    @MainActor
    private static func lastReviewTimestamps(
        for rows: [CollectionStore.BrowserRow],
        store: CollectionStore
    ) throws -> [Int64: Int64] {
        let ids = Array(Set(rows.map(\.card.id)))
        var result: [Int64: Int64] = [:]
        for batchStart in stride(from: 0, to: ids.count, by: 500) {
            let batch = Array(ids[batchStart..<min(batchStart + 500, ids.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try store.db.query("SELECT cid, MAX(id) FROM revlog WHERE cid IN (\(placeholders)) GROUP BY cid", bind: { stmt in
                for (index, id) in batch.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id)
                }
            }) { stmt in
                result[sqlite3_column_int64(stmt, 0)] = sqlite3_column_int64(stmt, 1)
            }
        }
        return result
    }

    /// Moves cards the way Anki's `move_into_filtered_deck` does.
    /// The original due stays in `odue`. A future due becomes a study position.
    /// With reschedule off, every card is shown from the review queue.
    @MainActor
    static func install(cardIDs: [Int64], deckID: Int64, reschedule: Bool, store: CollectionStore) throws {
        let now = Int64(Date().timeIntervalSince1970)
        var position = orderOrigin
        for cid in cardIDs {
            guard var card = try store.fetchCard(id: cid), card.odid == 0 else { continue }
            let originalDue = card.due
            card.odid = card.did
            card.odue = originalDue
            card.did = deckID
            if !reschedule {
                card.queue = AnkiCard.Queue.review.rawValue
            }
            if originalDue > 0 {
                card.due = position
            }
            card.mod = now
            card.usn = -1
            position += 1
            try store.updateCard(card)
        }
    }

    @MainActor
    static func empty(_ deck: AnkiDeck, store: CollectionStore) throws {
        guard deck.isFiltered else { return }
        try returnHome(deckID: deck.id, store: store)
        try store.refreshCounts()
    }

    @MainActor
    static func returnHome(deckID: Int64, store: CollectionStore) throws {
        var restoreIDs: [Int64] = []
        try store.db.query("SELECT id FROM cards WHERE did = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, deckID)
        }) { stmt in
            restoreIDs.append(sqlite3_column_int64(stmt, 0))
        }
        for cid in restoreIDs {
            guard var card = try store.fetchCard(id: cid), card.odid != 0 else { continue }
            restoreHome(&card)
            try store.updateCard(card)
        }
    }

    /// Puts a filtered card back on its home deck and restores the queue from its type.
    static func restoreHome(_ card: inout AnkiCard) {
        guard card.odid != 0 else { return }
        card.did = card.odid
        card.odid = 0
        if card.odue != 0 {
            card.due = card.odue
        }
        if card.queue >= 0 {
            card.queue = homeQueue(for: card)
        }
        card.odue = 0
        card.mod = Int64(Date().timeIntervalSince1970)
        card.usn = -1
    }

    /// Anki's filtered Due order compares day numbers and learning timestamps on one timeline.
    static func sortForGather(
        _ rows: inout [CollectionStore.BrowserRow],
        order: String,
        today: Int,
        now: Int,
        shuffle: Bool,
        lastSeen: [Int64: Int64] = [:],
        fsrs: Bool = false
    ) {
        switch order {
        case "due":
            rows.sort { lhs, rhs in
                let left = dueRank(lhs.card, today: today, now: now)
                let right = dueRank(rhs.card, today: today, now: now)
                if left != right { return left < right }
                if lhs.card.ord != rhs.card.ord { return lhs.card.ord < rhs.card.ord }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        case "added":
            rows.sort { lhs, rhs in
                if lhs.note.id != rhs.note.id { return lhs.note.id < rhs.note.id }
                if lhs.card.ord != rhs.card.ord { return lhs.card.ord < rhs.card.ord }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        case "latest":
            rows.sort { lhs, rhs in
                if lhs.note.id != rhs.note.id { return lhs.note.id > rhs.note.id }
                if lhs.card.ord != rhs.card.ord { return lhs.card.ord < rhs.card.ord }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        case "oldest":
            rows.sort { lhs, rhs in
                let left = lastSeen[lhs.card.id] ?? 0
                let right = lastSeen[rhs.card.id] ?? 0
                if left != right { return left < right }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        case "relative":
            rows.sort { lhs, rhs in
                let left = relativeOverdueness(lhs.card, today: today, now: now)
                let right = relativeOverdueness(rhs.card, today: today, now: now)
                if left != right { return left < right }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        case "retrievability", "retrievabilityDesc":
            guard fsrs else {
                rows.sort { lhs, rhs in
                    let left = relativeOverdueness(lhs.card, today: today, now: now)
                    let right = relativeOverdueness(rhs.card, today: today, now: now)
                    if left != right {
                        return order == "retrievability" ? left < right : left > right
                    }
                    return tieBreaksBefore(lhs.card, rhs.card)
                }
                return
            }
            rows.sort { lhs, rhs in
                let left = retrievability(lhs.card, today: today, now: now) ?? -1
                let right = retrievability(rhs.card, today: today, now: now) ?? -1
                if left != right {
                    return order == "retrievability" ? left < right : left > right
                }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        case "random":
            rows.shuffle()
        case "ivl":
            rows.sort { lhs, rhs in
                if lhs.card.ivl != rhs.card.ivl { return lhs.card.ivl < rhs.card.ivl }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        case "ivlDesc":
            rows.sort { lhs, rhs in
                if lhs.card.ivl != rhs.card.ivl { return lhs.card.ivl > rhs.card.ivl }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        case "lapses":
            rows.sort { lhs, rhs in
                if lhs.card.lapses != rhs.card.lapses { return lhs.card.lapses > rhs.card.lapses }
                return tieBreaksBefore(lhs.card, rhs.card)
            }
        default:
            if shuffle { rows.shuffle() }
        }
    }

    private static func tieBreaksBefore(_ lhs: AnkiCard, _ rhs: AnkiCard) -> Bool {
        let leftHash = SQLiteDatabase.fnvHash([lhs.id, lhs.mod])
        let rightHash = SQLiteDatabase.fnvHash([rhs.id, rhs.mod])
        if leftHash != rightHash { return leftHash < rightHash }
        return lhs.id < rhs.id
    }

    static func dueRank(_ card: AnkiCard, today: Int, now: Int) -> Int64 {
        let due = Int64(card.due)
        if due > 1_000_000_000 { return due }
        return (due - Int64(today)) * 86_400 + Int64(now)
    }

    private static func relativeOverdueness(_ card: AnkiCard, today: Int, now: Int) -> Double {
        if let _ = FSRSCardData.memory(in: card.data), let current = retrievability(card, today: today, now: now) {
            let decay = FSRSCardData.decay(in: card.data) ?? FSRS6.defaultDecay
            let retention = FSRSCardData.desiredRetention(in: card.data) ?? 0.9
            let current = max(Float(current), 0.0001)
            let desired = max(retention, 0.0001)
            let exponent = 1 / max(abs(decay), 0.0001)
            let relative = (pow(current, -exponent) - 1) / (pow(desired, -exponent) - 1)
            return -Double(relative)
        }
        let elapsedDays: Float
        if card.due > 365_000 {
            elapsedDays = Float(max(0, now - card.due)) / 86_400
        } else {
            elapsedDays = Float(max(0, today - (card.due - card.ivl)))
        }
        return -(Double(elapsedDays) + 0.001) / Double(max(card.ivl, 1))
    }

    private static func retrievability(_ card: AnkiCard, today: Int, now: Int) -> Double? {
        guard let memory = FSRSCardData.memory(in: card.data) else { return nil }
        let elapsedDays: Float
        if let reviewed = FSRSCardData.lastReview(in: card.data) {
            elapsedDays = Float(max(0, now - reviewed)) / 86_400
        } else if card.due > 365_000 {
            elapsedDays = Float(max(0, now - card.due)) / 86_400
        } else {
            elapsedDays = Float(max(0, today - (card.due - card.ivl)))
        }
        let decay = FSRSCardData.decay(in: card.data) ?? FSRS6.defaultDecay
        return Double(FSRS6.retrievability(daysElapsed: elapsedDays, stability: memory.stability, decay: decay))
    }

    static func homeQueue(for card: AnkiCard) -> Int {
        switch card.type {
        case 0: return AnkiCard.Queue.new.rawValue
        case 2: return AnkiCard.Queue.review.rawValue
        case 1, 3: return card.due > 100_000_000 ? AnkiCard.Queue.learning.rawValue : AnkiCard.Queue.dayLearn.rawValue
        default: return max(card.queue, 0)
        }
    }

    static func applyTagFilter(
        _ rows: [CollectionStore.BrowserRow],
        include: String?,
        exclude: String?
    ) -> [CollectionStore.BrowserRow] {
        let inc = tagSet(include)
        let exc = tagSet(exclude)
        guard !inc.isEmpty || !exc.isEmpty else { return rows }
        return rows.filter { row in
            let tags = row.note.tagList.map { $0.lowercased() }
            if !inc.isEmpty, !inc.contains(where: { matches(tags, selected: $0) }) { return false }
            if exc.contains(where: { matches(tags, selected: $0) }) { return false }
            return true
        }
    }

    /// Anki `tag:parent` also matches `parent::child`.
    private static func matches(_ noteTags: [String], selected: String) -> Bool {
        noteTags.contains { $0 == selected || $0.hasPrefix(selected + "::") }
    }

    private static func tagSet(_ raw: String?) -> Set<String> {
        Set(AnkiTag.split(raw ?? "").map { $0.lowercased() })
    }
}
