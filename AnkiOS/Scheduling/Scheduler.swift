import Foundation
import JavaScriptCore

@MainActor
final class Scheduler {
    unowned private let store: CollectionStore
    private var tracksCollectionUndo: Bool
    private struct UndoEntry {
        var cards: [AnkiCard]
        var notes: [AnkiNote] = []
        var revlogs: [AnkiRevlog] = []
        /// Deck and parents as they were, for the `*Today` study counters.
        var decks: [AnkiDeck] = []
        var queueUpdate: StudyQueues.Update? = nil
    }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var preserveAllUndoEntries = false

    private struct FilteredPreviewState {
        var seconds: Int
        var finished: Bool
        var customData: String? = nil
    }

    init(store: CollectionStore, tracksCollectionUndo: Bool = false) {
        self.store = store
        self.tracksCollectionUndo = tracksCollectionUndo
    }

    func clearRedoHistory() {
        redoStack.removeAll()
    }

    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Snapshot card state for undo (manual actions — no revlog / daily bump).
    func captureForUndo(_ card: AnkiCard) {
        captureForUndo([card])
    }

    func captureForUndo(_ cards: [AnkiCard]) {
        guard !cards.isEmpty else { return }
        redoStack.removeAll()
        pushUndo(UndoEntry(cards: cards))
        registerWithCollectionHistory()
    }

    func captureForUndo(_ note: AnkiNote) {
        redoStack.removeAll()
        pushUndo(UndoEntry(cards: [], notes: [note]))
        registerWithCollectionHistory()
    }

    private func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if !preserveAllUndoEntries && undoStack.count > 30 { undoStack.removeFirst() }
    }

    private func registerWithCollectionHistory() {
        guard tracksCollectionUndo else { return }
        store.registerStudyUndoOperation(self)
    }

    private func pushRedo(_ entry: UndoEntry) {
        redoStack.append(entry)
        if redoStack.count > 30 { redoStack.removeFirst() }
    }

    /// Anki only looks at the collection-wide `fsrs` switch.
    func usesFSRS(for deck: AnkiDeck) -> Bool {
        store.fsrsEnabled
    }

    func intervalLabels(for card: AnkiCard, deck: AnkiDeck) -> [Rating: String] {
        if deck.isFiltered && !(deck.resched ?? true) {
            let collapse = store.conf["collapseTime"] as? Int ?? 1200
            let states = filteredPreviewStates(card: card, deck: deck)
            return [
                .again: SM2Scheduler.buttonTime(seconds: states[.again]?.finished == true ? 0 : states[.again]?.seconds ?? previewDelay(deck, .again), collapse: collapse),
                .hard: SM2Scheduler.buttonTime(seconds: states[.hard]?.finished == true ? 0 : states[.hard]?.seconds ?? previewDelay(deck, .hard), collapse: collapse),
                .good: SM2Scheduler.buttonTime(seconds: states[.good]?.finished == true ? 0 : states[.good]?.seconds ?? previewDelay(deck, .good), collapse: collapse),
                .easy: SM2Scheduler.buttonTime(seconds: states[.easy]?.finished == true ? 0 : states[.easy]?.seconds ?? 0, collapse: collapse)
            ]
        }
        let cfg = store.config(for: schedulingDeck(for: card, in: deck))
        let day = store.schedDay()
        let now = Int(Date().timeIntervalSince1970)
        var map: [Rating: String] = [:]
        for (r, result) in scheduledResults(card: card, config: cfg, day: day, now: now, deck: deck) {
            map[r] = result.intervalLabel
        }
        return map
    }

    /// rslib `answer_card_inner`, followed by `update_queues_after_answering_card`.
    func answer(
        card: AnkiCard,
        deck: AnkiDeck,
        rating: Rating,
        timeTakenMS: Int,
        fromQueue: Bool = true,
        timestamp: Int? = nil,
        schedulingDay: Int? = nil
    ) throws {
        let queues = fromQueue ? store.studyQueuesForUpdate() : nil

        // Filtered deck with reschedule off: preview delays, scheduling stays untouched.
        if deck.isFiltered && !(deck.resched ?? true) {
            try answerPreview(
                before: card,
                deck: deck,
                rating: rating,
                timeTakenMS: timeTakenMS,
                queues: queues,
                timestamp: timestamp
            )
            return
        }

        let before = card
        let cfg = store.config(for: schedulingDeck(for: before, in: deck))
        let day = schedulingDay ?? store.schedDay()
        let now = timestamp ?? Int(Date().timeIntervalSince1970)
        let result = scheduledResults(card: card, config: cfg, day: day, now: now, deck: deck)[rating]
            ?? preview(card: card, config: cfg, rating: rating, day: day, now: now, deck: deck)
        var scheduled = result.card
        if before.type == AnkiCard.CardType.new.rawValue,
           scheduled.type != AnkiCard.CardType.new.rawValue,
           FSRSCardData.originalPosition(in: scheduled.data) == nil {
            let position = before.odid != 0 ? before.odue : before.due
            scheduled.data = FSRSCardData.mergingOriginalPosition(position, into: scheduled.data)
        }
        if deck.isFiltered, deck.resched ?? true, before.odid != 0 {
            scheduled.did = deck.id
            scheduled.odid = before.odid
            scheduled.odue = scheduled.due
        }
        scheduled.data = FSRSCardData.mergingLastReview(now, into: scheduled.data)
        let leeched = scheduled.lapses > before.lapses && leechThresholdMet(lapses: scheduled.lapses, threshold: cfg.lapse.leechFails)
        if leeched && cfg.lapse.leechAction == 0 {
            scheduled.queue = AnkiCard.Queue.suspended.rawValue
        }
        scheduled.mod = Int64(now)
        scheduled.usn = -1

        let recordedMS = cappedAnswerTime(timeTakenMS, config: cfg)
        let rev = AnkiRevlog(
            id: store.timestampID(),
            cid: card.id,
            usn: -1,
            ease: rating.rawValue,
            ivl: result.revlogIvl,
            lastIvl: result.lastIvl,
            factor: result.revlogFactor,
            time: recordedMS,
            type: revlogType(for: before, day: day)
        )
        try store.insertRevlog(rev)
        let decksBefore = store.deckWithParents(before.did)
        try updateDeckStats(for: before, milliseconds: recordedMS)
        var undoCards = [before]
        try burySiblingsIfNeeded(card: before, config: cfg, undoCards: &undoCards)
        try store.updateCard(scheduled)
        var undoNotes: [AnkiNote] = []
        if leeched {
            try addLeechTag(noteID: scheduled.nid, undoNotes: &undoNotes)
        }
        let queueUpdate = updateQueuesAfterAnswering(queues, card: scheduled, finishedPreview: false)
        redoStack.removeAll()
        pushUndo(UndoEntry(cards: undoCards, notes: undoNotes, revlogs: [rev], decks: decksBefore, queueUpdate: queueUpdate))
        registerWithCollectionHistory()
        try store.refreshCounts()
    }

    func gradeNow(cardIDs: [Int64], rating: Rating) throws {
        var seen = Set<Int64>()
        let ids = cardIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        let previousUndoStack = undoStack
        let previousRedoStack = redoStack
        let previousTracking = tracksCollectionUndo
        undoStack = []
        preserveAllUndoEntries = true
        tracksCollectionUndo = false
        let timestamp = Int(Date().timeIntervalSince1970)
        let schedulingDay = store.schedDay()
        do {
            try store.db.exec("BEGIN IMMEDIATE")
            for id in ids {
                guard let card = try store.fetchCard(id: id), let deck = store.deck(id: card.did) else { continue }
                try answer(
                    card: card,
                    deck: deck,
                    rating: rating,
                    timeTakenMS: 0,
                    fromQueue: false,
                    timestamp: timestamp,
                    schedulingDay: schedulingDay
                )
            }
            try store.db.exec("COMMIT")
        } catch {
            try? store.db.exec("ROLLBACK")
            undoStack = previousUndoStack
            redoStack = previousRedoStack
            tracksCollectionUndo = previousTracking
            preserveAllUndoEntries = false
            try? store.reloadMeta()
            try? store.refreshCounts()
            store.discardStudyQueues()
            throw error
        }
        tracksCollectionUndo = previousTracking
        preserveAllUndoEntries = false
        let entries = undoStack
        undoStack = previousUndoStack
        guard !entries.isEmpty else {
            redoStack = previousRedoStack
            return
        }
        var cardsByID: [Int64: AnkiCard] = [:]
        var notesByID: [Int64: AnkiNote] = [:]
        var decksByID: [Int64: AnkiDeck] = [:]
        for entry in entries {
            for card in entry.cards where cardsByID[card.id] == nil { cardsByID[card.id] = card }
            for note in entry.notes where notesByID[note.id] == nil { notesByID[note.id] = note }
            for deck in entry.decks where decksByID[deck.id] == nil { decksByID[deck.id] = deck }
        }
        let combined = UndoEntry(
            cards: Array(cardsByID.values),
            notes: Array(notesByID.values),
            revlogs: entries.flatMap(\.revlogs),
            decks: Array(decksByID.values)
        )
        pushUndo(combined)
        store.discardStudyQueues()
        registerWithCollectionHistory()
    }

    /// rslib `update_deck_stats_from_answer`: counted on the card's current deck.
    private func updateDeckStats(for card: AnkiCard, milliseconds: Int) throws {
        try store.updateDeckStats(
            deckID: card.did,
            newDelta: card.queue == AnkiCard.Queue.new.rawValue ? 1 : 0,
            reviewDelta: card.queue == AnkiCard.Queue.review.rawValue || card.queue == AnkiCard.Queue.dayLearn.rawValue ? 1 : 0,
            millisecondDelta: milliseconds
        )
    }

    /// rslib `cap_answer_secs`.
    private func cappedAnswerTime(_ milliseconds: Int, config: AnkiDeckConfig) -> Int {
        min(max(milliseconds, 0), max(config.maxTaken, 0) * 1000)
    }

    private func updateQueuesAfterAnswering(_ queues: StudyQueues?, card: AnkiCard, finishedPreview: Bool) -> StudyQueues.Update? {
        guard let queues else { return nil }
        let update = queues.applyAnswer(
            card: card,
            nextDayAt: store.studyNextDayAt,
            finishedPreview: finishedPreview,
            now: Int64(Date().timeIntervalSince1970)
        )
        if update == nil {
            store.discardStudyQueues()
        } else {
            store.finishStudyQueueUpdate(queues)
        }
        return update
    }

    /// Anki preview filtered deck: Again in 1 min, Hard in 10 min, Good and Easy return the card.
    private func previewDelay(_ deck: AnkiDeck, _ rating: Rating) -> Int {
        switch rating {
        case .again: return deck.previewAgain ?? FilteredDeckSupport.previewAgainSeconds
        case .hard: return deck.previewHard ?? FilteredDeckSupport.previewHardSeconds
        case .good: return deck.previewGood ?? FilteredDeckSupport.previewGoodSeconds
        case .easy: return 0
        }
    }

    private func answerPreview(
        before: AnkiCard,
        deck: AnkiDeck,
        rating: Rating,
        timeTakenMS: Int,
        queues: StudyQueues?,
        timestamp: Int? = nil
    ) throws {
        let state = filteredPreviewStates(card: before, deck: deck)[rating]
            ?? FilteredPreviewState(seconds: previewDelay(deck, rating), finished: previewDelay(deck, rating) == 0)
        let delay = state.finished ? 0 : state.seconds
        let finished = state.finished || delay == 0
        let now = timestamp ?? Int(Date().timeIntervalSince1970)
        var card = before
        if let customData = state.customData {
            card.data = FSRSCardData.mergingCustomData(customData, into: card.data)
        }
        if finished {
            FilteredDeckSupport.restoreHome(&card)
        } else {
            card.queue = AnkiCard.Queue.preview.rawValue
            card.due = now + AnkiFuzz.learningDelay(seconds: delay, cardID: before.id, reps: before.reps)
        }
        card.mod = Int64(now)
        card.usn = -1

        let recordedMS = cappedAnswerTime(timeTakenMS, config: store.config(for: schedulingDeck(for: before, in: deck)))
        let rev = AnkiRevlog(
            id: store.timestampID(),
            cid: before.id,
            usn: -1,
            ease: rating.rawValue,
            ivl: finished ? 0 : -delay,
            lastIvl: -previewDelay(deck, .again),
            factor: 0,
            time: recordedMS,
            type: 3
        )
        try store.insertRevlog(rev)
        let decksBefore = store.deckWithParents(before.did)
        try updateDeckStats(for: before, milliseconds: recordedMS)
        try store.updateCard(card)
        let queueUpdate = updateQueuesAfterAnswering(queues, card: card, finishedPreview: finished)
        redoStack.removeAll()
        pushUndo(UndoEntry(cards: [before], revlogs: [rev], decks: decksBefore, queueUpdate: queueUpdate))
        registerWithCollectionHistory()
        try store.refreshCounts()
    }

    /// rslib `maybe_bury_siblings`: siblings in queues gathered after the answered card's queue.
    private func burySiblingsIfNeeded(card: AnkiCard, config: AnkiDeckConfig, undoCards: inout [AnkiCard]) throws {
        func gatherOrder(_ queue: Int) -> Int {
            switch queue {
            case AnkiCard.Queue.learning.rawValue, AnkiCard.Queue.preview.rawValue: 0
            case AnkiCard.Queue.dayLearn.rawValue: 1
            case AnkiCard.Queue.review.rawValue: 2
            case AnkiCard.Queue.new.rawValue: 3
            default: Int.max
            }
        }
        let order = gatherOrder(card.queue)
        let buryNew = config.new.bury
        let buryReviews = config.rev.bury && order <= 2
        let buryDayLearn = config.buryInterdayLearning && order <= 1
        guard config.new.bury || config.rev.bury || config.buryInterdayLearning else { return }
        let now = Int64(Date().timeIntervalSince1970)
        for sid in try store.siblingCardIDs(of: card) where sid != card.id {
            guard var sibling = try store.fetchCard(id: sid) else { continue }
            let matches = (buryNew && sibling.queue == AnkiCard.Queue.new.rawValue)
                || (buryReviews && sibling.queue == AnkiCard.Queue.review.rawValue)
                || (buryDayLearn && sibling.queue == AnkiCard.Queue.dayLearn.rawValue)
            guard matches else { continue }
            undoCards.append(sibling)
            sibling.queue = AnkiCard.Queue.siblingBuried.rawValue
            sibling.mod = now
            sibling.usn = -1
            try store.updateCard(sibling)
        }
    }

    private func addLeechTag(noteID: Int64, undoNotes: inout [AnkiNote]) throws {
        guard let note = try store.fetchNote(id: noteID) else { return }
        var tags = note.tagList
        guard !tags.contains(where: { $0.caseInsensitiveCompare("leech") == .orderedSame }) else { return }
        undoNotes.append(note)
        tags.append("leech")
        try store.updateNote(note, fields: note.fields, tags: tags.joined(separator: " "))
    }

    func undo() throws {
        guard let entry = undoStack.last else { return }
        let queues = entry.queueUpdate == nil ? nil : store.studyQueuesForUpdate()
        let redoEntry = UndoEntry(
            cards: try entry.cards.compactMap { try store.fetchCard(id: $0.id) },
            notes: try entry.notes.compactMap { try store.fetchNote(id: $0.id) },
            revlogs: entry.revlogs,
            decks: entry.decks.compactMap { store.deck(id: $0.id) },
            queueUpdate: entry.queueUpdate
        )
        try store.db.exec("BEGIN IMMEDIATE")
        do {
            try restore(entry.cards, notes: entry.notes)
            for rev in entry.revlogs {
                try store.db.run("DELETE FROM revlog WHERE id = ?", bind: {
                    SQLiteDatabase.bindInt64($0, 1, rev.id)
                })
            }
            try store.restoreDecks(entry.decks)
            try store.refreshCounts()
            try store.db.exec("COMMIT")
        } catch {
            try? store.db.exec("ROLLBACK")
            throw error
        }
        undoStack.removeLast()
        if let update = entry.queueUpdate {
            applyQueueChange(queues, update) { $0.undoAnswer($1) }
        } else {
            store.discardStudyQueues()
        }
        pushRedo(redoEntry)
    }

    func redo() throws {
        guard let entry = redoStack.last else { return }
        let queues = entry.queueUpdate == nil ? nil : store.studyQueuesForUpdate()
        let undoEntry = UndoEntry(
            cards: try entry.cards.compactMap { try store.fetchCard(id: $0.id) },
            notes: try entry.notes.compactMap { try store.fetchNote(id: $0.id) },
            revlogs: entry.revlogs,
            decks: entry.decks.compactMap { store.deck(id: $0.id) },
            queueUpdate: entry.queueUpdate
        )
        try store.db.exec("BEGIN IMMEDIATE")
        do {
            try restore(entry.cards, notes: entry.notes)
            for rev in entry.revlogs { try store.insertRevlog(rev) }
            try store.restoreDecks(entry.decks)
            try store.refreshCounts()
            try store.db.exec("COMMIT")
        } catch {
            try? store.db.exec("ROLLBACK")
            throw error
        }
        redoStack.removeLast()
        if let update = entry.queueUpdate {
            applyQueueChange(queues, update) { $0.redoAnswer($1) }
        } else {
            store.discardStudyQueues()
        }
        pushUndo(undoEntry)
    }

    /// rslib `get_or_invalidate_queues`: only queues from the same build take the change.
    private func applyQueueChange(_ queues: StudyQueues?, _ update: StudyQueues.Update, _ change: (StudyQueues, StudyQueues.Update) -> Void) {
        guard let queues, queues.buildTime == update.queueBuildTime else {
            store.discardStudyQueues()
            return
        }
        change(queues, update)
        store.finishStudyQueueUpdate(queues)
    }

    private func restore(_ cards: [AnkiCard], notes: [AnkiNote]) throws {
        for card in cards.reversed() { try store.updateCard(card) }
        for note in notes {
            try store.db.run("UPDATE notes SET mod=?, usn=?, tags=?, flds=?, sfld=?, csum=?, flags=?, data=? WHERE id=?") { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, note.mod)
                SQLiteDatabase.bindInt(stmt, 2, note.usn)
                try SQLiteDatabase.bindText(stmt, 3, note.tags)
                try SQLiteDatabase.bindText(stmt, 4, note.flds)
                try SQLiteDatabase.bindText(stmt, 5, note.sfld)
                SQLiteDatabase.bindInt64(stmt, 6, note.csum)
                SQLiteDatabase.bindInt(stmt, 7, note.flags)
                try SQLiteDatabase.bindText(stmt, 8, note.data)
                SQLiteDatabase.bindInt64(stmt, 9, note.id)
            }
        }
    }

    /// Anki revlog type: 0 learning (including new), 1 review, 2 relearning.
    private func revlogType(for card: AnkiCard, day: Int) -> Int {
        switch card.type {
        case 2:
            let originalDue = card.odid != 0 ? card.odue : card.due
            return originalDue > day ? 3 : 1
        case 3: return 2
        default: return 0
        }
    }

    /// At the threshold, then every half threshold after that.
    private func leechThresholdMet(lapses: Int, threshold: Int) -> Bool {
        guard threshold > 0, lapses >= threshold else { return false }
        let half = max(1, Int((Double(threshold) / 2.0).rounded(.up)))
        return (lapses - threshold) % half == 0
    }

    private func preview(card: AnkiCard, config: AnkiDeckConfig, rating: Rating, day: Int, now: Int, deck: AnkiDeck) -> ScheduleResult {
        let collapse = store.conf["collapseTime"] as? Int ?? 1200
        let dayStart = store.schedDayStartTimestamp()
        let untilRollover = max(1, Int(dayStart + 86_400 - Int64(now)))
        let filtered = deck.isFiltered && (deck.resched ?? true)
        let realDue = (filtered && card.odid != 0) ? card.odue : card.due
        let forecast = usesFSRS(for: deck)
            ? fsrsForecast(card: card, config: config, dayStart: dayStart, now: now, schedulingDue: realDue)
            : nil
        let easy = EasyDayLoad.isActive(config.easyDayPercents)
        let dueCounts = easy ? store.dueCountsForPreset(config.id, today: day) : []
        return SM2Scheduler.preview(
            card: card,
            config: config,
            rating: rating,
            day: day,
            now: now,
            collapse: collapse,
            secsUntilRollover: untilRollover,
            schedulingDue: realDue,
            clampReviewDue: !filtered,
            fsrs: forecast,
            dueCounts: dueCounts,
            nextDayAt: Int(dayStart) + 86_400
        )
    }

    private func scheduledResults(card: AnkiCard, config: AnkiDeckConfig, day: Int, now: Int, deck: AnkiDeck) -> [Rating: ScheduleResult] {
        var results = Dictionary(uniqueKeysWithValues: Rating.allCases.map { rating in
            (rating, preview(card: card, config: config, rating: rating, day: day, now: now, deck: deck))
        })
        guard let script = store.conf["cardStateCustomizer"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return results
        }

        var states: [String: Any] = ["current": schedulingState(for: card, now: now, day: day)]
        for rating in Rating.allCases {
            guard let result = results[rating] else { continue }
            states[rating.customSchedulingKey] = futureSchedulingState(for: result.card, deck: deck, now: now, day: day)
        }
        let context: [String: Any] = [
            "deckName": deck.name,
            "seed": card.id,
            "desiredRetention": store.deck(id: card.odid != 0 ? card.odid : card.did)?.desiredRetention ?? config.desiredRetention ?? 0.9,
            "decay": FSRS6.filledParameters(config.activeFSRSWeights).last.map(Double.init) ?? 0
        ]
        guard let changed = CardStateCustomizer.apply(script, states: states, customData: FSRSCardData.customData(in: card.data), context: context) else {
            return results
        }
        for rating in Rating.allCases {
            guard var result = results[rating], let payload = changed[rating.customSchedulingKey] as? [String: Any] else { continue }
            applySchedulingState(payload, to: &result, now: now, day: day)
            results[rating] = result
        }
        return results
    }

    private func filteredPreviewStates(card: AnkiCard, deck: AnkiDeck) -> [Rating: FilteredPreviewState] {
        var statesByRating = Dictionary(uniqueKeysWithValues: Rating.allCases.map {
            let seconds = previewDelay(deck, $0)
            return ($0, FilteredPreviewState(seconds: seconds, finished: seconds == 0))
        })
        guard let script = store.conf["cardStateCustomizer"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return statesByRating
        }
        let customData = FSRSCardData.customData(in: card.data)
        var states: [String: Any] = ["current": ["filtered": ["preview": ["scheduledSecs": 0, "finished": false]], "customData": customData]]
        for rating in Rating.allCases {
            let state = statesByRating[rating] ?? FilteredPreviewState(seconds: 0, finished: true)
            states[rating.customSchedulingKey] = ["filtered": ["preview": ["scheduledSecs": state.seconds, "finished": state.finished]], "customData": customData]
        }
        let config = store.config(for: schedulingDeck(for: card, in: deck))
        let context: [String: Any] = [
            "deckName": deck.name,
            "seed": card.id,
            "desiredRetention": store.deck(id: card.odid != 0 ? card.odid : card.did)?.desiredRetention ?? config.desiredRetention ?? 0.9,
            "decay": FSRS6.filledParameters(config.activeFSRSWeights).last.map(Double.init) ?? 0
        ]
        guard let changed = CardStateCustomizer.apply(script, states: states, customData: customData, context: context) else {
            return statesByRating
        }
        for rating in Rating.allCases {
            guard let state = changed[rating.customSchedulingKey] as? [String: Any],
                  let filtered = state["filtered"] as? [String: Any],
                  let preview = filtered["preview"] as? [String: Any],
                  let seconds = CardStateCustomizer.integer(preview["scheduledSecs"]) else { continue }
            statesByRating[rating] = FilteredPreviewState(
                seconds: max(seconds, 0),
                finished: (preview["finished"] as? Bool) ?? (seconds == 0),
                customData: state["customData"] as? String
            )
        }
        return statesByRating
    }

    private func schedulingState(for card: AnkiCard, now: Int, day: Int) -> [String: Any] {
        var source = card
        if card.odid != 0 {
            source.did = card.odid
            source.due = card.odue
            source.odid = 0
            source.odue = 0
            source.queue = source.type == AnkiCard.CardType.review.rawValue
                ? AnkiCard.Queue.review.rawValue
                : (source.type == AnkiCard.CardType.relearning.rawValue ? AnkiCard.Queue.dayLearn.rawValue : AnkiCard.Queue.learning.rawValue)
        }
        let normal = normalSchedulingState(for: source, now: now, day: day)
        let state: [String: Any] = card.odid != 0
            ? ["filtered": ["rescheduling": ["originalState": normal]]]
            : ["normal": normal]
        var result = state
        result["customData"] = FSRSCardData.customData(in: card.data)
        return result
    }

    private func futureSchedulingState(for card: AnkiCard, deck: AnkiDeck, now: Int, day: Int) -> [String: Any] {
        if deck.isFiltered && !(deck.resched ?? true) {
            let seconds = max(card.due - now, 0)
            return ["filtered": ["preview": ["scheduledSecs": seconds, "finished": seconds == 0]], "customData": FSRSCardData.customData(in: card.data)]
        }
        let normal = normalSchedulingState(for: card, now: now, day: day)
        if deck.isFiltered && (deck.resched ?? true) {
            return ["filtered": ["rescheduling": ["originalState": normal]], "customData": FSRSCardData.customData(in: card.data)]
        }
        return ["normal": normal, "customData": FSRSCardData.customData(in: card.data)]
    }

    private func normalSchedulingState(for card: AnkiCard, now: Int, day: Int) -> [String: Any] {
        if card.type == AnkiCard.CardType.new.rawValue {
            return ["new": ["position": card.due]]
        }
        var review: [String: Any] = [
            "scheduledDays": max(card.ivl, 0),
            "elapsedDays": card.type == AnkiCard.CardType.review.rawValue
                ? max(card.ivl + max(day - card.due, 0), 0)
                : max(card.ivl, 0),
            "easeFactor": Double(card.factor) / 1000,
            "lapses": card.lapses,
            "leeched": false
        ]
        if let memory = FSRSCardData.memory(in: card.data) {
            review["memoryState"] = ["stability": Double(memory.stability), "difficulty": Double(memory.difficulty)]
        }
        if card.type == AnkiCard.CardType.review.rawValue {
            return ["review": review]
        }
        let remaining = card.left >= 1000 ? card.left % 1000 : card.left
        let stepsConfig = store.deck(id: card.did).map { store.config(for: $0) } ?? .default()
        let steps = card.type == AnkiCard.CardType.relearning.rawValue
            ? stepsConfig.lapse.delays
            : stepsConfig.new.delays
        let stepIndex = min(max(steps.count - remaining, 0), max(steps.count - 1, 0))
        let scheduledSeconds = steps.indices.contains(stepIndex) ? max(Int(steps[stepIndex] * 60), 0) : 0
        let elapsedSeconds: Int
        if card.queue == AnkiCard.Queue.dayLearn.rawValue {
            let elapsedDays = max(day - card.due + max(scheduledSeconds / 86_400, 1), 0)
            elapsedSeconds = elapsedDays * 86_400
        } else {
            let latestReviewID = (try? store.db.scalarInt64(
                "SELECT COALESCE(MAX(id), 0) FROM revlog WHERE cid = ?",
                bind: { SQLiteDatabase.bindInt64($0, 1, card.id) }
            )) ?? 0
            let lastAnsweredAt = latestReviewID > 0
                ? Int(latestReviewID / 1000)
                : card.due - scheduledSeconds
            elapsedSeconds = max(now - lastAnsweredAt, 0)
        }
        var learning: [String: Any] = [
            "remainingSteps": remaining,
            "scheduledSecs": scheduledSeconds,
            "elapsedSecs": elapsedSeconds
        ]
        if let memory = FSRSCardData.memory(in: card.data) {
            learning["memoryState"] = ["stability": Double(memory.stability), "difficulty": Double(memory.difficulty)]
        }
        if card.type == AnkiCard.CardType.relearning.rawValue {
            return ["relearning": ["review": review, "learning": learning]]
        }
        return ["learning": learning]
    }

    private func applySchedulingState(_ payload: [String: Any], to result: inout ScheduleResult, now: Int, day: Int) {
        if let customData = payload["customData"] as? String {
            result.card.data = FSRSCardData.mergingCustomData(customData, into: result.card.data)
        }
        let normal = (payload["normal"] as? [String: Any])
            ?? ((payload["filtered"] as? [String: Any])?["rescheduling"] as? [String: Any])?["originalState"] as? [String: Any]
        if let normal {
            if let value = normal["new"] as? [String: Any], let position = CardStateCustomizer.integer(value["position"]) {
                result.card.due = position
            }
            if let value = normal["learning"] as? [String: Any] {
                applyLearningState(value, to: &result, now: now, day: day)
            }
            if let value = normal["review"] as? [String: Any] {
                applyReviewState(value, to: &result, day: day)
            }
            if let value = normal["relearning"] as? [String: Any] {
                if let review = value["review"] as? [String: Any] { applyReviewState(review, to: &result, day: day) }
                if let learning = value["learning"] as? [String: Any] { applyLearningState(learning, to: &result, now: now, day: day) }
            }
        }
        if let filtered = payload["filtered"] as? [String: Any],
           let preview = filtered["preview"] as? [String: Any],
           let seconds = CardStateCustomizer.integer(preview["scheduledSecs"]) {
            let safeSeconds = max(seconds, 0)
            if (preview["finished"] as? Bool) == true || safeSeconds == 0 {
                FilteredDeckSupport.restoreHome(&result.card)
            } else {
                result.card.queue = AnkiCard.Queue.preview.rawValue
                result.card.due = now + AnkiFuzz.learningDelay(
                    seconds: safeSeconds,
                    cardID: result.card.id,
                    reps: max(result.card.reps - 1, 0)
                )
            }
            result.intervalLabel = SM2Scheduler.buttonTime(seconds: safeSeconds, collapse: store.conf["collapseTime"] as? Int ?? 1200)
            result.revlogIvl = safeSeconds == 0 ? 0 : -safeSeconds
        }
    }

    private func applyLearningState(_ state: [String: Any], to result: inout ScheduleResult, now: Int, day: Int) {
        guard let seconds = CardStateCustomizer.integer(state["scheduledSecs"]) else { return }
        let safeSeconds = max(seconds, 0)
        if let remaining = CardStateCustomizer.integer(state["remainingSteps"]) { result.card.left = max(remaining, 0) }
        if let memory = state["memoryState"] as? [String: Any] {
            result.card.data = FSRSCardData.merging(result.card.data, memory: memory)
        }
        if result.card.queue == AnkiCard.Queue.dayLearn.rawValue {
            let days = Int(ceil(Double(safeSeconds) / 86_400))
            result.card.due = day + days
            result.revlogIvl = days
            result.intervalLabel = SM2Scheduler.buttonTime(seconds: safeSeconds, collapse: store.conf["collapseTime"] as? Int ?? 1200)
        } else {
            result.card.queue = AnkiCard.Queue.learning.rawValue
            result.card.due = now + AnkiFuzz.learningDelay(
                seconds: safeSeconds,
                cardID: result.card.id,
                reps: max(result.card.reps - 1, 0)
            )
            result.revlogIvl = safeSeconds == 0 ? 0 : -safeSeconds
            result.intervalLabel = SM2Scheduler.buttonTime(seconds: safeSeconds, collapse: store.conf["collapseTime"] as? Int ?? 1200)
        }
    }

    private func applyReviewState(_ state: [String: Any], to result: inout ScheduleResult, day: Int) {
        guard let days = CardStateCustomizer.integer(state["scheduledDays"]) else { return }
        let interval = max(days, 0)
        result.card.queue = AnkiCard.Queue.review.rawValue
        result.card.type = AnkiCard.CardType.review.rawValue
        result.card.ivl = interval
        result.card.due = day + interval
        result.revlogIvl = interval
        result.intervalLabel = SM2Scheduler.buttonTime(seconds: interval * 86_400, collapse: store.conf["collapseTime"] as? Int ?? 1200)
        if let ease = CardStateCustomizer.number(state["easeFactor"]) {
            result.card.factor = Int((ease * 1000).rounded())
            result.revlogFactor = result.card.factor
        }
        if let lapses = CardStateCustomizer.integer(state["lapses"]) { result.card.lapses = max(lapses, 0) }
        if let memory = state["memoryState"] as? [String: Any] {
            result.card.data = FSRSCardData.merging(result.card.data, memory: memory)
        }
    }

    private func fsrsForecast(card: AnkiCard, config: AnkiDeckConfig, dayStart: Int64, now: Int, schedulingDue: Int) -> FSRSForecast {
        var scheduled = card
        if let cutoff = Self.ignoreReviewsCutoff(config.ignoreRevlogsBeforeDate),
           let reviewed = FSRSCardData.lastReview(in: card.data),
           reviewed < cutoff {
            scheduled.data = ""
        }
        let nextDay = Int(dayStart) + 86_400
        let days: Int
        if let reviewed = FSRSCardData.lastReview(in: scheduled.data) {
            days = max(0, (nextDay - reviewed) / 86_400)
        } else if scheduled.type == 2 {
            if FSRSCardData.memory(in: scheduled.data) == nil {
                days = 0
            } else {
                let due = min(schedulingDue, store.schedDay())
                days = max(0, scheduled.ivl - (due - store.schedDay()))
            }
        } else {
            days = 0
        }
        return FSRS6.forecast(
            card: scheduled,
            weights: config.activeFSRSWeights,
            desiredRetention: store.deck(id: card.odid != 0 ? card.odid : card.did)?.desiredRetention
                ?? config.desiredRetention
                ?? 0.9,
            historicalRetention: config.historicalRetention,
            daysElapsed: days,
            reviewedAt: now,
            shortTermWithSteps: store.conf["fsrsShortTermWithSteps"] as? Bool ?? false
        )
    }

    private func schedulingDeck(for card: AnkiCard, in sessionDeck: AnkiDeck) -> AnkiDeck {
        let deckID = card.odid != 0 ? card.odid : card.did
        return store.deck(id: deckID) ?? sessionDeck
    }

    /// Anki preset field `ignoreRevlogsBeforeDate` (`YYYY-MM-DD`). Reviews before that day do not keep the stored FSRS memory.
    private static func ignoreReviewsCutoff(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date.map { Int($0.timeIntervalSince1970) }
    }
}

#if ANKIOS_PARITY_HARNESS
extension Scheduler {
    func harnessResults(card: AnkiCard, deck: AnkiDeck) -> [Rating: ScheduleResult] {
        let cfg = store.config(for: schedulingDeck(for: card, in: deck))
        return scheduledResults(card: card, config: cfg, day: store.schedDay(), now: Int(Date().timeIntervalSince1970), deck: deck)
    }
}
#endif

private enum CardStateCustomizer {
    static func apply(_ script: String, states: [String: Any], customData: String, context: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(states), JSONSerialization.isValidJSONObject(context),
              let stateData = try? JSONSerialization.data(withJSONObject: states),
              let contextData = try? JSONSerialization.data(withJSONObject: context),
              let stateJSON = String(data: stateData, encoding: .utf8),
              let contextJSON = String(data: contextData, encoding: .utf8) else { return nil }
        let js = JSContext()
        js?.exceptionHandler = { _, _ in }
        js?.evaluateScript("var console = { log: function() {}, warn: function() {}, error: function() {} };")
        guard js?.evaluateScript("var states = \(stateJSON); var customData = \(jsonString(customData)); var ctx = \(contextJSON); var __customDone = false; var __customOutput = null;") != nil else { return nil }
        let mutation = """
        (async function(states, customData, ctx) {
            try {
                \(script)
                globalThis.__customOutput = JSON.stringify(states);
            } catch (error) {
                globalThis.__customOutput = null;
            } finally {
                globalThis.__customDone = true;
            }
        })(states, customData, ctx);
        """
        guard js?.evaluateScript(mutation) != nil, js?.exception == nil else { return nil }
        let deadline = Date().addingTimeInterval(3)
        while js?.evaluateScript("__customDone")?.toBool() != true && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard js?.evaluateScript("__customDone")?.toBool() == true,
              let output = js?.evaluateScript("__customOutput")?.toString(),
              let outputData = output.data(using: .utf8),
              let changed = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else { return nil }
        return changed
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.isFinite else { return nil }
        return Int(number.rounded())
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
}

private extension Rating {
    var customSchedulingKey: String {
        switch self {
        case .again: "again"
        case .hard: "hard"
        case .good: "good"
        case .easy: "easy"
        }
    }
}
