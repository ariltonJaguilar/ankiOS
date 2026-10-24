import Foundation

struct ScheduleResult: Sendable {
    var card: AnkiCard
    var intervalLabel: String
    var revlogIvl: Int
    var lastIvl: Int
    var revlogFactor: Int
}

struct LoadBalancerDueCard: Sendable {
    var noteID: Int64
    var deckConfigID: Int64
    var dayOffset: Int
}

struct ReviewLoadBalancerContext: Sendable {
    var cards: [LoadBalancerDueCard]
    var nextDayAt: Int

    func findInterval(
        interval: Float,
        minimum: Int,
        maximum: Int,
        deckConfigID: Int64,
        noteID: Int64?,
        fuzz: Float,
        easyDayPercents: [Double]
    ) -> Int? {
        guard interval <= 90, minimum <= 90 else { return nil }
        let presetCards = cards.filter { $0.deckConfigID == deckConfigID }
        guard !presetCards.isEmpty else { return nil }
        let (lower, upper) = AnkiFuzz.constrainedBounds(interval: interval, minimum: minimum, maximum: maximum)
        let candidates = Array(lower...upper)
        let dueByDay = Dictionary(grouping: presetCards, by: \.dayOffset)
        let counts = candidates.map { dueByDay[$0]?.count ?? 0 }
        let weekdays = candidates.map { weekday(interval: $0, nextDayAt: nextDayAt) }
        let easyDays = parseEasyDays(easyDayPercents)
        let easyModifiers = easyDayModifiers(easyDays, weekdays: weekdays, counts: counts)
        let siblingOffsets: Set<Int>
        if let noteID {
            siblingOffsets = Set(cards.lazy.filter { $0.noteID == noteID }.map(\.dayOffset))
        } else {
            siblingOffsets = []
        }
        var weights: [Float] = []
        weights.reserveCapacity(candidates.count)
        for (index, day) in candidates.enumerated() {
            let count = counts[index]
            let weight: Float
            if count == 0 {
                weight = 1
            } else {
                let countWeight = powf(1 / Float(count), 2.15)
                let intervalFactor = 1 / Float(max(day, 1))
                let intervalWeight = intervalFactor * intervalFactor * intervalFactor
                let sibling = siblingModifier(day: day, siblingOffsets: siblingOffsets)
                weight = countWeight * intervalWeight * sibling * easyModifiers[index]
            }
            weights.append(weight)
        }
        var total: Float = 0
        var cumulative: [Float] = []
        cumulative.reserveCapacity(weights.count)
        for weight in weights {
            total += weight
            cumulative.append(total)
        }
        guard total > 0 else { return nil }
        let chosen = min(max(fuzz, 0), Float(1).nextDown) * total
        guard let index = cumulative.firstIndex(where: { $0 > chosen }) else {
            return candidates.last
        }
        return candidates[index]
    }

    private func parseEasyDays(_ percentages: [Double]) -> [Float] {
        if percentages.count == 7 { return percentages.map(Float.init) }
        return Array(repeating: 1, count: 7)
    }

    private func easyDayModifiers(_ percentages: [Float], weekdays: [Int], counts: [Int]) -> [Float] {
        let totalCount = counts.reduce(0, +)
        let totalPercent = weekdays.reduce(Float.zero) { partial, weekday in
            partial + loadModifier(percentages[weekday])
        }
        return zip(weekdays, counts).map { weekday, count in
            let stored = percentages[weekday]
            if stored == 0 { return 0.0001 }
            if stored == 1 { return 1 }
            let otherCount = Float(totalCount - count)
            let otherPercent = totalPercent - 0.5
            let threshold = otherPercent == 0 ? Float.infinity : otherCount / otherPercent
            return Float(count) / 0.5 > threshold ? 0.0001 : 1
        }
    }

    private func loadModifier(_ percentage: Float) -> Float {
        if percentage == 0 { return 0.0001 }
        if percentage == 1 { return 1 }
        return 0.5
    }

    private func siblingModifier(day: Int, siblingOffsets: Set<Int>) -> Float {
        let steps = [-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5]
        let modifiers: [Float] = [1, 0.8, 0.6, 0.4, 0.2, 0.000001, 0.2, 0.4, 0.6, 0.8, 1]
        return siblingOffsets.reduce(Float(1)) { product, siblingDay in
            guard let index = steps.firstIndex(of: day - siblingDay) else { return product }
            return product * modifiers[index]
        }
    }

    private func weekday(interval: Int, nextDayAt: Int) -> Int {
        let timestamp = nextDayAt + (interval - 1) * 86_400
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return (calendar.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(timestamp))) + 5) % 7
    }
}

/// Anki v3 scheduler (SM-2), matching `rslib` learning steps, review intervals and button times.
enum SM2Scheduler {
    static func preview(
        card: AnkiCard,
        config: AnkiDeckConfig,
        rating: Rating,
        day: Int,
        now: Int,
        collapse: Int = 1200,
        secsUntilRollover: Int = 86_400,
        schedulingDue: Int? = nil,
        clampReviewDue: Bool = true,
        fsrs: FSRSForecast? = nil,
        dueCounts: [Int] = [],
        nextDayAt: Int = 0,
        loadBalancer: ReviewLoadBalancerContext? = nil
    ) -> ScheduleResult {
        let ctx = Context(
            config: config,
            day: day,
            now: now,
            collapse: max(collapse, 0),
            secsUntilRollover: max(secsUntilRollover, 1),
            fuzz: AnkiFuzz.factor(cardID: card.id, reps: card.reps),
            schedulingDue: schedulingDue ?? card.due,
            clampReviewDue: clampReviewDue,
            fsrs: fsrs,
            dueCounts: dueCounts,
            nextDayAt: nextDayAt,
            loadBalancer: loadBalancer,
            noteID: card.nid
        )
        let learnSteps = ctx.learningSteps
        let relearnSteps = ctx.relearningSteps

        let previous = card
        var next = card
        // v2 packed `left` as steps*1000+remaining. v3 keeps the plain remainder.
        if next.type == 1 || next.type == 3 {
            next.left %= 1000
        }
        let outcome: Outcome
        switch card.type {
        case 2:
            outcome = review(&next, rating: rating, ctx: ctx)
        case 3:
            outcome = relearn(&next, steps: relearnSteps, rating: rating, ctx: ctx)
        case 1:
            outcome = learning(&next, steps: learnSteps, remaining: next.left, rating: rating, ctx: ctx)
        default:
            // A new card is answered as a learning card that just failed, so every step is still ahead.
            outcome = learning(&next, steps: learnSteps, remaining: learnSteps.count, rating: rating, ctx: ctx)
        }

        if let forecast = ctx.fsrs {
            next.data = FSRSCardData.merging(
                next.data,
                item: forecast.item(for: rating),
                retention: forecast.desiredRetention,
                decay: forecast.decay,
                reviewedAt: forecast.reviewedAt
            )
        }
        next.reps += 1
        next.mod = Int64(Date().timeIntervalSince1970)
        let revlogFactor = ctx.fsrs.map {
            Int((FSRS6.shiftedDifficulty($0.item(for: rating).difficulty) * 1000).rounded())
        } ?? next.factor
        return ScheduleResult(
            card: next,
            intervalLabel: outcome.label,
            revlogIvl: outcome.revlogIvl,
            lastIvl: previousInterval(previous, learn: learnSteps, relearn: relearnSteps, secsUntilRollover: ctx.secsUntilRollover),
            revlogFactor: revlogFactor
        )
    }

    // MARK: - States

    private enum FSRSEmptyStepDefaults {
        static let learning: [Double] = [1, 5, 30, 1440]
        static let relearning: [Double] = [10, 1440]
    }

    private struct Context {
        var config: AnkiDeckConfig
        var day: Int
        var now: Int
        var collapse: Int
        var secsUntilRollover: Int
        var fuzz: Double
        var schedulingDue: Int
        var clampReviewDue: Bool
        var fsrs: FSRSForecast?
        var dueCounts: [Int]
        var nextDayAt: Int
        var loadBalancer: ReviewLoadBalancerContext?
        var noteID: Int64
        var learningSteps: LearningSteps {
            LearningSteps(minutes: fsrs != nil && config.new.delays.isEmpty ? FSRSEmptyStepDefaults.learning : config.new.delays)
        }
        var relearningSteps: LearningSteps {
            LearningSteps(minutes: fsrs != nil && config.lapse.delays.isEmpty ? FSRSEmptyStepDefaults.relearning : config.lapse.delays)
        }
        var graduationEase: Int { fsrs == nil ? initialEase : 2300 }
        var maxIvl: Int { max(config.rev.maxIvl, 1) }
        var ease: Float { Float(config.rev.ease4) }
        var hard: Float { Float(config.rev.hardFactor) }
        var modifier: Float { Float(config.rev.ivlFct) }
        var initialEase: Int { config.new.initialFactor }
        var goodDays: Int { max(config.new.ints.first ?? 1, 1) }
        var easyDays: Int { max(config.new.ints.count > 1 ? config.new.ints[1] : 4, 1) }
        var lapseMin: Int { max(config.lapse.minInt, 1) }
        var lapseMult: Double { config.lapse.mult }
    }

    private struct Outcome {
        var label: String
        var revlogIvl: Int
    }

    /// Learning or new. `remaining` is how many steps are still ahead, the way Anki stores `cards.left`.
    private static func learning(
        _ card: inout AnkiCard,
        steps: LearningSteps,
        remaining: Int,
        rating: Rating,
        ctx: Context
    ) -> Outcome {
        switch rating {
        case .again:
            if let delay = steps.againDelay() {
                return enterLearning(&card, delay: delay, remaining: steps.count, type: 1, ctx: ctx, keepInterval: false)
            }
            return leaveLearning(&card, rating: .again, remaining: steps.count, stepsEmpty: true, ctx: ctx)
        case .hard:
            if let delay = steps.hardDelay(remaining: remaining) {
                return enterLearning(&card, delay: delay, remaining: remaining, type: 1, ctx: ctx, keepInterval: false)
            }
            return leaveLearning(&card, rating: .hard, remaining: remaining, stepsEmpty: true, ctx: ctx)
        case .good:
            if let delay = steps.goodDelay(remaining: remaining) {
                let left = steps.remainingAfterGood(remaining: remaining)
                return enterLearning(&card, delay: delay, remaining: left, type: 1, ctx: ctx, keepInterval: false)
            }
            return leaveLearning(&card, rating: .good, remaining: remaining, stepsEmpty: steps.count == 0, ctx: ctx)
        case .easy:
            return leaveLearningEasy(&card, ctx: ctx)
        }
    }

    private static func relearn(
        _ card: inout AnkiCard,
        steps: LearningSteps,
        rating: Rating,
        ctx: Context
    ) -> Outcome {
        let remaining = card.left
        switch rating {
        case .again:
            if let delay = steps.againDelay() {
                card.ivl = failingInterval(card, ctx: ctx)
                return enterLearning(&card, delay: delay, remaining: steps.count, type: 3, ctx: ctx, keepInterval: true)
            }
            if ctx.fsrs != nil {
                return leaveRelearn(&card, rating: .again, remaining: steps.count, stepsEmpty: true, ctx: ctx)
            }
            return finishRelearn(&card, days: max(card.ivl, 1), ctx: ctx)
        case .hard:
            if let delay = steps.hardDelay(remaining: remaining) {
                return enterLearning(&card, delay: delay, remaining: remaining, type: 3, ctx: ctx, keepInterval: true)
            }
            if ctx.fsrs != nil {
                return leaveRelearn(&card, rating: .hard, remaining: remaining, stepsEmpty: true, ctx: ctx)
            }
            return finishRelearn(&card, days: max(card.ivl, 1), ctx: ctx)
        case .good:
            if let delay = steps.goodDelay(remaining: remaining) {
                let left = steps.remainingAfterGood(remaining: remaining)
                return enterLearning(&card, delay: delay, remaining: left, type: 3, ctx: ctx, keepInterval: true)
            }
            if ctx.fsrs != nil {
                return leaveRelearn(&card, rating: .good, remaining: remaining, stepsEmpty: steps.count == 0, ctx: ctx)
            }
            return finishRelearn(&card, days: max(card.ivl, 1), ctx: ctx)
        case .easy:
            if ctx.fsrs != nil {
                return leaveRelearnEasy(&card, ctx: ctx)
            }
            return finishRelearn(&card, days: max(card.ivl, 1) + 1, ctx: ctx)
        }
    }

    private static func review(_ card: inout AnkiCard, rating: Rating, ctx: Context) -> Outcome {
        let scheduledDays = max(card.ivl, 0)
        let due = ctx.clampReviewDue ? min(ctx.schedulingDue, ctx.day) : ctx.schedulingDue
        let elapsed = max(0, scheduledDays - (due - ctx.day))
        let daysLate = elapsed - scheduledDays
        var ease = easeFactor(card)

        switch rating {
        case .again:
            ease = max(1.3, ease - 0.2)
            card.factor = storeEase(ease)
            card.lapses += 1
            let steps = ctx.relearningSteps
            if let forecast = ctx.fsrs {
                let days = max(1, Int(forecast.again.interval.rounded()))
                card.ivl = days
                if let delay = steps.againDelay() {
                    return enterLearning(&card, delay: delay, remaining: steps.count, type: 3, ctx: ctx, keepInterval: true)
                }
                if forecast.keepsShortTerm(forecast.again.interval, stepsEmpty: true) {
                    let secs = max(Int(forecast.again.interval * 86_400), 1)
                    return enterLearning(&card, delay: secs, remaining: steps.count, type: 3, ctx: ctx, keepInterval: true)
                }
                return finishRelearn(&card, days: days, ctx: ctx)
            }
            let days = lapsedInterval(scheduled: max(scheduledDays, 1), ctx: ctx)
            card.ivl = days
            if let delay = steps.againDelay() {
                return enterLearning(&card, delay: delay, remaining: steps.count, type: 3, ctx: ctx, keepInterval: true)
            }
            return finishRelearn(&card, days: days, ctx: ctx)
        case .hard, .good, .easy:
            if let forecast = ctx.fsrs {
                let hard = fsrsPassing(forecast.hard.interval, previous: scheduledDays, atLeast: nil, ctx: ctx)
                let good = fsrsPassing(forecast.good.interval, previous: scheduledDays, atLeast: hard + 1, ctx: ctx)
                let easyInterval = fsrsPassing(forecast.easy.interval, previous: scheduledDays, atLeast: good + 1, ctx: ctx)
                let chosen: Int
                switch rating {
                case .hard:
                    ease = max(1.3, ease - 0.15)
                    chosen = hard
                case .easy:
                    ease += 0.15
                    chosen = easyInterval
                default:
                    chosen = good
                }
                card.factor = storeEase(ease)
                return finishRelearn(&card, days: chosen, ctx: ctx)
            }
            let hard: Int
            let good: Int
            let easyInterval: Int
            if daysLate < 0 {
                let scheduled = Float(max(scheduledDays, 1))
                let elapsedF = Float(elapsed)
                hard = roundClamped(max(elapsedF * ctx.hard, scheduled * ctx.hard / 2), ctx: ctx)
                good = roundClamped(max(elapsedF * ease, scheduled), ctx: ctx)
                let reduced = ctx.ease - (ctx.ease - 1.0) / 2.0
                easyInterval = roundClamped(max(elapsedF * ease, scheduled) * reduced, ctx: ctx)
            } else {
                let current = Float(max(scheduledDays, 1))
                let late = Float(daysLate)
                let hardMinimum = ctx.hard <= 1 ? 0 : scheduledDays + 1
                hard = constrain(current * ctx.hard, minimum: hardMinimum, ctx: ctx)
                let goodMinimum = ctx.hard <= 1 ? scheduledDays + 1 : hard + 1
                good = constrain((current + late / 2.0) * ease, minimum: goodMinimum, ctx: ctx)
                easyInterval = constrain((current + late) * ease * ctx.ease, minimum: good + 1, ctx: ctx)
            }
            let days: Int
            switch rating {
            case .hard:
                ease = max(1.3, ease - 0.15)
                days = hard
            case .easy:
                ease += 0.15
                days = easyInterval
            default:
                days = good
            }
            card.factor = storeEase(ease)
            return finishRelearn(&card, days: days, ctx: ctx)
        }
    }

    // MARK: - Applying a state

    /// Graduating from learning. With FSRS, the interval comes from the button's next state.
    private static func leaveLearning(
        _ card: inout AnkiCard,
        rating: Rating,
        remaining: Int,
        stepsEmpty: Bool,
        ctx: Context
    ) -> Outcome {
        guard let forecast = ctx.fsrs else {
            return graduate(&card, days: ctx.goodDays, ctx: ctx)
        }
        let item = forecast.item(for: rating)
        if forecast.keepsShortTerm(item.interval, stepsEmpty: stepsEmpty) {
            let secs = max(Int(item.interval * 86_400), 1)
            let left = rating == .hard ? remaining : 0
            return enterLearning(&card, delay: secs, remaining: left, type: 1, ctx: ctx, keepInterval: false)
        }
        let days = fuzzDays(Double(max(item.interval, 1).rounded()), minimum: 1, ctx: ctx)
        card.factor = ctx.graduationEase
        return finishRelearn(&card, days: days, ctx: ctx)
    }

    private static func leaveLearningEasy(_ card: inout AnkiCard, ctx: Context) -> Outcome {
        guard let forecast = ctx.fsrs else {
            return graduate(&card, days: ctx.easyDays, ctx: ctx)
        }
        let good = fuzzDays(Double(forecast.good.interval), minimum: 1, ctx: ctx)
        let easy = fuzzDays(Double(max(forecast.easy.interval, 1).rounded()), minimum: good + 1, ctx: ctx)
        card.factor = ctx.graduationEase
        return finishRelearn(&card, days: easy, ctx: ctx)
    }

    private static func leaveRelearn(
        _ card: inout AnkiCard,
        rating: Rating,
        remaining: Int,
        stepsEmpty: Bool,
        ctx: Context
    ) -> Outcome {
        guard let forecast = ctx.fsrs else {
            return finishRelearn(&card, days: max(card.ivl, 1), ctx: ctx)
        }
        let item = forecast.item(for: rating)
        if forecast.keepsShortTerm(item.interval, stepsEmpty: stepsEmpty) {
            let secs = max(Int(item.interval * 86_400), 1)
            let left = rating == .hard ? remaining : 0
            card.ivl = max(1, Int(item.interval.rounded()))
            return enterLearning(&card, delay: secs, remaining: left, type: 3, ctx: ctx, keepInterval: true)
        }
        let days = fuzzDays(Double(max(item.interval, 1).rounded()), minimum: 1, ctx: ctx)
        return finishRelearn(&card, days: days, ctx: ctx)
    }

    private static func leaveRelearnEasy(_ card: inout AnkiCard, ctx: Context) -> Outcome {
        guard let forecast = ctx.fsrs else {
            return finishRelearn(&card, days: max(card.ivl, 1) + 1, ctx: ctx)
        }
        let good = fuzzDays(Double(forecast.good.interval), minimum: 1, ctx: ctx)
        let easy = fuzzDays(Double(max(forecast.easy.interval, 1).rounded()), minimum: good + 1, ctx: ctx)
        return finishRelearn(&card, days: easy, ctx: ctx)
    }

    /// Failing interval kept on the card while it is still in relearning steps.
    private static func failingInterval(_ card: AnkiCard, ctx: Context) -> Int {
        if let forecast = ctx.fsrs {
            return max(1, Int(forecast.again.interval.rounded()))
        }
        return lapsedInterval(scheduled: max(card.ivl, 1), ctx: ctx)
    }

    private static func fsrsPassing(_ interval: Float, previous: Int, atLeast extra: Int?, ctx: Context) -> Int {
        var minimum = max(1, AnkiFuzz.preservedMinimum(interval: Double(interval), previous: previous, maximum: ctx.maxIvl))
        if let extra { minimum = max(minimum, extra) }
        return fuzzDays(Double(interval), minimum: minimum, ctx: ctx)
    }

    private static func fuzzDays(_ interval: Double, minimum: Int, ctx: Context) -> Int {
        if let loadBalancer = ctx.loadBalancer {
            return loadBalancer.findInterval(
                interval: Float(interval),
                minimum: minimum,
                maximum: ctx.maxIvl,
                deckConfigID: ctx.config.id,
                noteID: ctx.config.rev.bury ? ctx.noteID : nil,
                fuzz: Float(ctx.fuzz),
                easyDayPercents: ctx.config.easyDayPercents
            ) ?? AnkiFuzz.apply(factor: ctx.fuzz, interval: interval, minimum: minimum, maximum: ctx.maxIvl)
        }
        if EasyDayLoad.isActive(ctx.config.easyDayPercents) {
            return EasyDayLoad.pick(
                interval: interval,
                minimum: minimum,
                maximum: ctx.maxIvl,
                fuzz: ctx.fuzz,
                percents: ctx.config.easyDayPercents,
                dueCounts: ctx.dueCounts,
                nextDayAt: ctx.nextDayAt
            )
        }
        return AnkiFuzz.apply(factor: ctx.fuzz, interval: interval, minimum: minimum, maximum: ctx.maxIvl)
    }

    private static func enterLearning(
        _ card: inout AnkiCard,
        delay: Int,
        remaining: Int,
        type: Int,
        ctx: Context,
        keepInterval: Bool
    ) -> Outcome {
        card.type = type
        card.left = remaining
        if !keepInterval, type == 1 { card.ivl = 0 }
        let kind = IntervalKind.seconds(delay).crossingDay(secsUntilRollover: ctx.secsUntilRollover)
        switch kind {
        case .seconds(let secs):
            card.queue = 1
            card.due = ctx.now + AnkiFuzz.learningDelay(seconds: secs, cardID: card.id, reps: card.reps)
            return Outcome(label: buttonTime(seconds: secs, collapse: ctx.collapse), revlogIvl: -secs)
        case .days(let days):
            card.queue = 3
            card.due = ctx.day + days
            return Outcome(label: buttonTime(seconds: days * 86_400, collapse: ctx.collapse), revlogIvl: days)
        }
    }

    private static func graduate(_ card: inout AnkiCard, days requested: Int, ctx: Context) -> Outcome {
        let scheduled = fuzzDays(Double(requested), minimum: 1, ctx: ctx)
        card.type = 2
        card.queue = 2
        card.left = 0
        card.ivl = scheduled
        card.due = ctx.day + scheduled
        card.factor = ctx.initialEase
        return Outcome(label: buttonTime(seconds: scheduled * 86_400, collapse: ctx.collapse), revlogIvl: scheduled)
    }

    private static func finishRelearn(_ card: inout AnkiCard, days: Int, ctx: Context) -> Outcome {
        let scheduled = min(ctx.maxIvl, max(1, days))
        card.type = 2
        card.queue = 2
        card.left = 0
        card.ivl = scheduled
        card.due = ctx.day + scheduled
        return Outcome(label: buttonTime(seconds: scheduled * 86_400, collapse: ctx.collapse), revlogIvl: scheduled)
    }

    private static func lapsedInterval(scheduled: Int, ctx: Context) -> Int {
        fuzzDays(Double(Float(max(scheduled, 1)) * Float(ctx.lapseMult)), minimum: ctx.lapseMin, ctx: ctx)
    }

    private static func constrain(_ raw: Float, minimum: Int, ctx: Context) -> Int {
        fuzzDays(Double(raw * ctx.modifier), minimum: minimum, ctx: ctx)
    }

    /// Early reviews are rounded, without the fuzz applied to on-time reviews.
    private static func roundClamped(_ raw: Float, ctx: Context) -> Int {
        let maximum = ctx.maxIvl
        let scaled = raw * ctx.modifier
        return min(maximum, max(1, Int(scaled.rounded())))
    }

    private static func easeFactor(_ card: AnkiCard) -> Float {
        let ease = Float(card.factor) / 1000
        return ease >= 1.3 ? ease : 2.5
    }

    private static func storeEase(_ ease: Float) -> Int {
        Int(min(65_535, max(0, (ease * 1000).rounded())))
    }

    /// rslib `IntervalKind::as_revlog_interval` after `maybe_as_days`.
    private static func previousInterval(_ card: AnkiCard, learn: LearningSteps, relearn: LearningSteps, secsUntilRollover: Int) -> Int {
        let seconds: Int
        switch card.type {
        case 2: return card.ivl
        case 0: return 0
        case 3: seconds = relearn.currentDelay(remaining: card.left)
        default: seconds = learn.currentDelay(remaining: card.left)
        }
        switch IntervalKind.seconds(seconds).crossingDay(secsUntilRollover: secsUntilRollover) {
        case .days(let days): return days
        case .seconds(let secs): return secs == 0 ? 0 : -secs
        }
    }

    /// Anki's Fluent time spans: isolate the number (`U+2068`/`U+2069`) and use a
    /// comma decimal, matching `describe_next_states` in pt_BR.
    static func buttonTime(seconds: Int, collapse: Int) -> String {
        if seconds <= 0 { return "(fim)" }
        let text = unitLabel(seconds: seconds)
        if seconds < collapse { return "<\(text)" }
        return text
    }

    private static func isolate(_ number: String) -> String {
        "\u{2068}\(number)\u{2069}"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func unitLabel(seconds: Int) -> String {
        let secs = Double(seconds)
        if secs < 60 {
            return "\(isolate("\(max(Int(secs.rounded()), seconds == 0 ? 0 : 1))"))s"
        }
        if secs < 3_600 {
            return "\(isolate("\(max(Int((secs / 60).rounded()), 1))"))min(s)"
        }
        if secs < 86_400 {
            let hours = (secs / 3_600 * 10).rounded() / 10
            if hours == hours.rounded() { return "\(isolate("\(Int(hours))"))h" }
            return "\(isolate(decimal(hours)))h"
        }
        let month = 86_400.0 * 365.0 / 12.0
        let year = 86_400.0 * 365.0
        if secs < month {
            return "\(isolate("\(max(Int((secs / 86_400).rounded()), 1))"))dia(s)"
        }
        if secs < year {
            let months = (secs / month * 10).rounded() / 10
            if months == months.rounded() { return "\(isolate("\(Int(months))"))mês(es)" }
            return "\(isolate(decimal(months)))mês(es)"
        }
        let years = (secs / year * 10).rounded() / 10
        if years == years.rounded() { return "\(isolate("\(Int(years))"))a" }
        return "\(isolate(decimal(years)))a"
    }
}

private enum IntervalKind {
    case seconds(Int)
    case days(Int)

    func crossingDay(secsUntilRollover: Int) -> IntervalKind {
        switch self {
        case .seconds(let secs) where secs >= secsUntilRollover:
            return .days(((secs - secsUntilRollover) / 86_400) + 1)
        default:
            return self
        }
    }
}

private struct LearningSteps {
    var minutes: [Double]
    var count: Int { minutes.count }

    func secs(at index: Int) -> Int? {
        guard minutes.indices.contains(index) else { return nil }
        return Int(Float(minutes[index]) * 60.0)
    }

    /// Anki indexes steps from the end of the remaining count.
    func index(remaining: Int) -> Int {
        guard count > 0 else { return 0 }
        let rem = remaining % 1000
        return min(max(count - rem, 0), count - 1)
    }

    func againDelay() -> Int? { secs(at: 0) }

    func hardDelay(remaining: Int) -> Int? {
        guard count > 0 else { return nil }
        let idx = index(remaining: remaining)
        let current = secs(at: idx) ?? secs(at: 0) ?? 0
        if idx == 0 { return hardDelayForFirstStep(again: current) }
        return current
    }

    func goodDelay(remaining: Int) -> Int? {
        secs(at: index(remaining: remaining) + 1)
    }

    func remainingAfterGood(remaining: Int) -> Int {
        max(count - (index(remaining: remaining) + 1), 0)
    }

    func currentDelay(remaining: Int) -> Int {
        guard count > 0 else { return 0 }
        return secs(at: index(remaining: remaining)) ?? 0
    }

    private func hardDelayForFirstStep(again: Int) -> Int {
        if let next = secs(at: 1) {
            return roundDaysIfNeeded((again + next) / 2)
        }
        return roundDaysIfNeeded(min(again * 3 / 2, again + 86_400))
    }

    private func roundDaysIfNeeded(_ secs: Int) -> Int {
        guard secs > 86_400 else { return secs }
        return Int((Float(secs) / Float(86_400)).rounded(.toNearestOrAwayFromZero)) * 86_400
    }
}

/// Anki's review-interval fuzz. The width of the window matches `rslib`; the position inside it is stable per card.
enum AnkiFuzz {
    static func learningDelay(seconds: Int, cardID: Int64, reps: Int) -> Int {
        let seconds = max(seconds, 0)
        let extra = min(Int((Float(seconds) * 0.25).rounded(.down)), 300)
        guard extra > 0 else { return seconds }
        let range = UInt32(extra)
        let threshold = (UInt32(0) &- range) % range
        let words = randomWords(cardID: cardID, reps: reps)
        for word in words {
            let product = UInt64(word) * UInt64(range)
            let low = UInt32(truncatingIfNeeded: product)
            if low >= threshold { return seconds + Int(product >> 32) }
        }
        return seconds + Int((UInt64(words.last ?? 0) * UInt64(range)) >> 32)
    }

    static func factor(cardID: Int64, reps: Int) -> Double {
        let randomWord = randomWords(cardID: cardID, reps: reps)[0]
        let mantissa = randomWord >> 9
        let value = Float(bitPattern: 0x3f80_0000 | mantissa) - 1
        return Double(value)
    }

    private static func randomWords(cardID: Int64, reps: Int) -> [UInt32] {
        let cardBits = UInt64(bitPattern: cardID)
        var seedState = cardBits &+ UInt64(max(reps, 0))
        var seed = [UInt32](repeating: 0, count: 8)
        for index in seed.indices {
            seedState = seedState &* 6_364_136_223_846_793_005 &+ 11_634_580_027_462_260_723
            let shifted = UInt32(truncatingIfNeeded: (((seedState >> 18) ^ seedState) >> 27))
            let rotation = UInt32(seedState >> 59)
            seed[index] = (shifted >> rotation) | (shifted << ((32 &- rotation) & 31))
        }

        let initial: [UInt32] = [
            0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574,
            seed[0], seed[1], seed[2], seed[3], seed[4], seed[5], seed[6], seed[7],
            0, 0, 0, 0
        ]
        var block = initial

        func rotateLeft(_ value: UInt32, _ amount: UInt32) -> UInt32 {
            (value &<< amount) | (value &>> (32 &- amount))
        }

        func quarterRound(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ words: inout [UInt32]) {
            words[a] = words[a] &+ words[b]
            words[d] = rotateLeft(words[d] ^ words[a], 16)
            words[c] = words[c] &+ words[d]
            words[b] = rotateLeft(words[b] ^ words[c], 12)
            words[a] = words[a] &+ words[b]
            words[d] = rotateLeft(words[d] ^ words[a], 8)
            words[c] = words[c] &+ words[d]
            words[b] = rotateLeft(words[b] ^ words[c], 7)
        }

        for _ in 0..<6 {
            quarterRound(0, 4, 8, 12, &block)
            quarterRound(1, 5, 9, 13, &block)
            quarterRound(2, 6, 10, 14, &block)
            quarterRound(3, 7, 11, 15, &block)
            quarterRound(0, 5, 10, 15, &block)
            quarterRound(1, 6, 11, 12, &block)
            quarterRound(2, 7, 8, 13, &block)
            quarterRound(3, 4, 9, 14, &block)
        }

        return block.indices.map { block[$0] &+ initial[$0] }
    }

    static func preservedMinimum(interval: Double, previous: Int, maximum: Int) -> Int {
        let interval = Float(interval)
        let rounded = Int(interval.rounded())
        let upper = constrainedBounds(interval: interval, minimum: 1, maximum: maximum).1
        if rounded > previous { return previous + 1 }
        if previous <= upper { return previous }
        return 0
    }

    static func apply(factor: Double?, interval: Double, minimum: Int, maximum: Int) -> Int {
        let maximum = max(maximum, 1)
        let minimum = min(max(minimum, 1), maximum)
        let interval = Float(interval)
        guard let factor else {
            return min(maximum, max(minimum, Int(interval.rounded())))
        }
        let (lower, upper) = constrainedBounds(interval: interval, minimum: minimum, maximum: maximum)
        let picked = Float(lower) + Float(factor) * Float(1 + upper - lower)
        return min(maximum, max(minimum, Int(picked.rounded(.down))))
    }

    static func constrainedBounds(interval: Float, minimum: Int, maximum: Int) -> (Int, Int) {
        let clamped = min(max(interval, Float(minimum)), Float(maximum))
        var lower = Int((clamped - delta(clamped)).rounded())
        var upper = Int((clamped + delta(clamped)).rounded())
        lower = min(max(lower, minimum), maximum)
        upper = min(max(upper, minimum), maximum)
        if upper == lower, upper > 2, upper < maximum { upper = lower + 1 }
        return (lower, upper)
    }

    private static func delta(_ interval: Float) -> Float {
        guard interval >= 2.5 else { return 0 }
        let ranges: [(start: Float, end: Float, factor: Float)] = [
            (2.5, 7, 0.15),
            (7, 20, 0.1),
            (20, .greatestFiniteMagnitude, 0.05)
        ]
        return ranges.reduce(1.0) { partial, range in
            partial + range.factor * max(0, min(interval, range.end) - range.start)
        }
    }
}

/// Anki easy days: inside the fuzz window, minimum weekdays are almost never chosen
/// and reduced weekdays drop out once they already hold more than their share.
enum EasyDayLoad {
    static func isActive(_ percents: [Double]) -> Bool {
        percents.count == 7 && percents.contains { $0 < 0.99 }
    }

    static func pick(
        interval: Double,
        minimum: Int,
        maximum: Int,
        fuzz: Double,
        percents: [Double],
        dueCounts: [Int],
        nextDayAt: Int
    ) -> Int {
        let plain = AnkiFuzz.apply(factor: fuzz, interval: interval, minimum: minimum, maximum: maximum)
        guard nextDayAt > 0, interval <= 90, minimum <= 90 else { return plain }
        let (lower, upper) = bounds(interval: interval, minimum: minimum, maximum: maximum)
        let days = Array(lower...upper)
        let weekdays = days.map { weekday(interval: $0, nextDayAt: nextDayAt) }
        let counts = days.map { dueCounts.indices.contains($0) ? dueCounts[$0] : 0 }
        let modifiers = easyModifiers(percents: percents, weekdays: weekdays, counts: counts)
        var weighted: [(Int, Double)] = []
        for (index, day) in days.enumerated() {
            let count = counts[index]
            let weight: Double
            if count == 0 {
                weight = 1
            } else {
                let byCount = pow(1.0 / Double(count), 2.15)
                let byInterval = pow(1.0 / Double(max(day, 1)), 3)
                weight = byCount * byInterval * modifiers[index]
            }
            weighted.append((day, max(weight, 0)))
        }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return plain }
        var cursor = min(max(fuzz, 0), 0.999999) * total
        for item in weighted {
            cursor -= item.1
            if cursor <= 0 { return item.0 }
        }
        return weighted.last?.0 ?? plain
    }

    private static func bounds(interval: Double, minimum: Int, maximum: Int) -> (Int, Int) {
        let clamped = min(max(interval, Double(minimum)), Double(maximum))
        var lower = Int((clamped - delta(clamped)).rounded())
        var upper = Int((clamped + delta(clamped)).rounded())
        lower = min(max(lower, minimum), maximum)
        upper = min(max(upper, minimum), maximum)
        if upper < lower { upper = lower }
        return (lower, upper)
    }

    private static func delta(_ interval: Double) -> Double {
        guard interval >= 2.5 else { return 0 }
        let ranges: [(start: Double, end: Double, factor: Double)] = [
            (2.5, 7, 0.15),
            (7, 20, 0.1),
            (20, .infinity, 0.05)
        ]
        return ranges.reduce(1.0) { partial, range in
            partial + range.factor * max(0, min(interval, range.end) - range.start)
        }
    }

    /// Monday is 0, matching Anki's `num_days_from_monday`.
    private static func weekday(interval: Int, nextDayAt: Int) -> Int {
        let stamp = nextDayAt + max(0, interval - 1) * 86_400
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(stamp)))
        return (day + 5) % 7
    }

    /// 1.0 normal, 0 minimum, anything else reduced (load 0.5) until that day is overloaded.
    private static func easyModifiers(percents: [Double], weekdays: [Int], counts: [Int]) -> [Double] {
        let totalCount = counts.reduce(0, +)
        let totalPercent = weekdays.reduce(0.0) { partial, day in
            partial + load(percents[day])
        }
        return zip(weekdays, counts).map { day, count in
            let stored = percents[day]
            if stored == 0 { return 0.0001 }
            if stored >= 0.99 { return 1 }
            let otherCount = Double(totalCount - count)
            let otherPercent = totalPercent - 0.5
            let normalized = Double(count) / 0.5
            let threshold = otherPercent == 0 ? Double.infinity : otherCount / otherPercent
            return normalized > threshold ? 0.0001 : 1
        }
    }

    private static func load(_ percent: Double) -> Double {
        if percent == 0 { return 0.0001 }
        if percent >= 0.99 { return 1 }
        return 0.5
    }
}
