import Foundation

@MainActor
final class Scheduler {
    private let store: CollectionStore
    private var undoStack: [(AnkiCard, AnkiRevlog?, DailyBump?)] = []

    private struct DailyBump {
        let deckID: Int64
        let wasNew: Bool
        let wasReview: Bool
        let wasLearn: Bool
        let timeMS: Int
    }

    init(store: CollectionStore) {
        self.store = store
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// Snapshot card state for undo (manual actions — no revlog / daily bump).
    func captureForUndo(_ card: AnkiCard) {
        undoStack.append((card, nil, nil))
    }

    func usesFSRS(for deck: AnkiDeck) -> Bool {
        _ = deck
        let sched = (store.conf["scheduler"] as? String)?.lowercased() ?? "sm2"
        return sched == "fsrs"
    }

    func intervalLabels(for card: AnkiCard, deck: AnkiDeck) -> [Rating: String] {
        if deck.isFiltered && !(deck.resched ?? true) {
            let collapse = store.conf["collapseTime"] as? Int ?? 1200
            return [
                .again: SM2Scheduler.buttonTime(seconds: previewDelay(deck, .again), collapse: collapse),
                .hard: SM2Scheduler.buttonTime(seconds: previewDelay(deck, .hard), collapse: collapse),
                .good: SM2Scheduler.buttonTime(seconds: previewDelay(deck, .good), collapse: collapse),
                .easy: SM2Scheduler.buttonTime(seconds: 0, collapse: collapse)
            ]
        }
        let cfg = store.config(for: deck)
        let day = store.schedDay()
        let now = Int(Date().timeIntervalSince1970)
        var map: [Rating: String] = [:]
        for r in Rating.allCases {
            let result = preview(card: card, config: cfg, rating: r, day: day, now: now, deck: deck)
            map[r] = result.intervalLabel
        }
        return map
    }

    func answer(card: AnkiCard, deck: AnkiDeck, rating: Rating, timeTakenMS: Int) throws {
        let before = card
        let wasNew = before.queue == 0
        let wasReview = before.queue == 2
        let wasLearn = before.queue == 1 || before.queue == 3

        // Filtered deck with reschedule off: preview delays, scheduling stays untouched.
        if deck.isFiltered && !(deck.resched ?? true) {
            try answerPreview(before: before, deck: deck, rating: rating, timeTakenMS: timeTakenMS)
            return
        }

        let cfg = store.config(for: deck)
        let day = store.schedDay()
        let now = Int(Date().timeIntervalSince1970)
        let result = preview(card: card, config: cfg, rating: rating, day: day, now: now, deck: deck)
        var scheduled = result.card
        if deck.isFiltered, deck.resched ?? true, before.odid != 0 {
            if scheduled.queue == 2 {
                scheduled.did = before.odid
                scheduled.odid = 0
                scheduled.odue = 0
            } else {
                scheduled.did = deck.id
                scheduled.odid = before.odid
                scheduled.odue = scheduled.due
            }
        }
        try store.updateCard(scheduled)

        // Anki caps recorded answer time at deck option maxTaken (seconds).
        let maxMS = max(cfg.maxTaken, 1) * 1000
        let recordedMS = min(max(timeTakenMS, 1), maxMS)

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

        let bump = DailyBump(
            deckID: before.did,
            wasNew: wasNew,
            wasReview: wasReview,
            wasLearn: wasLearn,
            timeMS: recordedMS
        )
        try store.recordTodayStudy(
            deckID: bump.deckID,
            wasNew: bump.wasNew,
            wasReview: bump.wasReview,
            wasLearn: bump.wasLearn,
            timeMS: bump.timeMS
        )
        undoStack.append((before, rev, bump))
        try applyLeechIfNeeded(card: scheduled, before: before, config: cfg)
        try burySiblingsIfNeeded(card: before, config: cfg)
        try store.refreshCounts()
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

    private func answerPreview(before: AnkiCard, deck: AnkiDeck, rating: Rating, timeTakenMS: Int) throws {
        let delay: Int
        switch rating {
        case .again: delay = previewDelay(deck, .again)
        case .hard: delay = previewDelay(deck, .hard)
        case .good: delay = previewDelay(deck, .good)
        case .easy: delay = 0
        }
        var card = before
        if delay == 0 {
            FilteredDeckSupport.restoreHome(&card)
        } else {
            let fuzzed = SM2Scheduler.fuzzedLearningSeconds(delay, card: before)
            card.queue = AnkiCard.Queue.preview.rawValue
            card.due = Int(Date().timeIntervalSince1970) + fuzzed
            card.mod = Int64(Date().timeIntervalSince1970)
        }
        try store.updateCard(card)

        let maxMS = max(store.config(for: deck).maxTaken, 1) * 1000
        let recordedMS = min(max(timeTakenMS, 1), maxMS)
        let rev = AnkiRevlog(
            id: store.timestampID(),
            cid: before.id,
            usn: -1,
            ease: rating.rawValue,
            ivl: delay == 0 ? 0 : -delay,
            lastIvl: -previewDelay(deck, .again),
            factor: 0,
            time: recordedMS,
            type: 3
        )
        try store.insertRevlog(rev)
        let bump = DailyBump(
            deckID: before.did,
            wasNew: false,
            wasReview: before.queue == AnkiCard.Queue.review.rawValue,
            wasLearn: false,
            timeMS: recordedMS
        )
        try store.recordTodayStudy(
            deckID: bump.deckID,
            wasNew: bump.wasNew,
            wasReview: bump.wasReview,
            wasLearn: bump.wasLearn,
            timeMS: bump.timeMS
        )
        undoStack.append((before, rev, bump))
        try store.refreshCounts()
    }

    /// Anki “bury related new/review/day-learn cards until tomorrow”.
    private func burySiblingsIfNeeded(card: AnkiCard, config: AnkiDeckConfig) throws {
        let buryNew = config.new.bury
        let buryRev = config.rev.bury
        let buryDayLearn = config.buryInterdayLearning
        guard buryNew || buryRev || buryDayLearn else { return }
        let siblings = try store.siblingCardIDs(of: card).filter { $0 != card.id }
        for sid in siblings {
            guard let sibling = try store.fetchCard(id: sid), sibling.queue >= 0 else { continue }
            if sibling.queue == 0, buryNew {
                try store.setCardsQueue([sid], queue: -2) // sibling-buried
            } else if sibling.queue == 2, buryRev {
                try store.setCardsQueue([sid], queue: -2)
            } else if sibling.queue == 3, buryDayLearn {
                try store.setCardsQueue([sid], queue: -2)
            }
        }
    }

    /// Anki leech: when lapses hit threshold, suspend (0) or tag (1).
    private func applyLeechIfNeeded(card: AnkiCard, before: AnkiCard, config: AnkiDeckConfig) throws {
        let threshold = config.lapse.leechFails
        guard card.lapses > before.lapses, leechThresholdMet(lapses: card.lapses, threshold: threshold) else { return }
        if config.lapse.leechAction == 0 {
            try store.setCardsQueue([card.id], queue: -1)
        }
        if let note = try store.fetchNote(id: card.nid) {
            var tags = note.tagList
            if !tags.contains("leech") {
                tags.append("leech")
                try store.updateNote(note, fields: note.fields, tags: tags.joined(separator: " "))
            }
        }
    }

    func undo() throws {
        guard let (card, rev, bump) = undoStack.popLast() else { return }
        try store.updateCard(card)
        if let rev {
            try store.db.run("DELETE FROM revlog WHERE id = ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, rev.id)
            })
        }
        // Best-effort: decrement today's counters if still same day.
        if let bump {
            try store.recordTodayStudyUndo(
                deckID: bump.deckID,
                wasNew: bump.wasNew,
                wasReview: bump.wasReview,
                wasLearn: bump.wasLearn,
                timeMS: bump.timeMS
            )
        }
        try store.refreshCounts()
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
        let forecast = usesFSRS(for: deck) ? fsrsForecast(card: card, config: config, dayStart: dayStart, now: now, schedulingDue: realDue) : nil
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
            let due = min(schedulingDue, store.schedDay())
            days = max(0, scheduled.ivl - (due - store.schedDay()))
        } else {
            days = 0
        }
        return FSRS6.forecast(
            card: scheduled,
            weights: config.fsrsWeights,
            desiredRetention: config.desiredRetention ?? 0.9,
            daysElapsed: days,
            reviewedAt: now,
            shortTermWithSteps: store.conf["fsrsShortTermWithSteps"] as? Bool ?? false
        )
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
