import Foundation

struct ScheduleResult: Sendable {
    var card: AnkiCard
    var intervalLabel: String
    var revlogIvl: Int
    var lastIvl: Int
    var revlogFactor: Int
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
        nextDayAt: Int = 0
    ) -> ScheduleResult {
        let learnSteps = LearningSteps(minutes: config.new.delays)
        let relearnSteps = LearningSteps(minutes: config.lapse.delays)
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
            nextDayAt: nextDayAt
        )

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
            lastIvl: previousInterval(previous, learn: learnSteps, relearn: relearnSteps),
            revlogFactor: revlogFactor
        )
    }

    // MARK: - States

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
        var maxIvl: Int { max(config.rev.maxIvl, 1) }
        var ease: Double { config.rev.ease4 }
        var hard: Double { config.rev.hardFactor }
        var modifier: Double { config.rev.ivlFct }
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
            let steps = LearningSteps(minutes: ctx.config.lapse.delays)
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
                let scheduled = Double(max(scheduledDays, 1))
                let elapsedF = Double(elapsed)
                hard = roundClamped(max(elapsedF * ctx.hard, scheduled * ctx.hard / 2.0), ctx: ctx)
                good = roundClamped(max(elapsedF * ease, scheduled), ctx: ctx)
                let reduced = ctx.ease - (ctx.ease - 1.0) / 2.0
                easyInterval = roundClamped(max(elapsedF * ease, scheduled) * reduced, ctx: ctx)
            } else {
                let current = Double(max(scheduledDays, 1))
                let late = Double(daysLate)
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
        card.factor = ctx.initialEase
        return finishRelearn(&card, days: days, ctx: ctx)
    }

    private static func leaveLearningEasy(_ card: inout AnkiCard, ctx: Context) -> Outcome {
        guard let forecast = ctx.fsrs else {
            return graduate(&card, days: ctx.easyDays, ctx: ctx)
        }
        let good = fuzzDays(Double(forecast.good.interval), minimum: 1, ctx: ctx)
        let easy = fuzzDays(Double(max(forecast.easy.interval, 1).rounded()), minimum: good + 1, ctx: ctx)
        card.factor = ctx.initialEase
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
            card.due = ctx.now + learningFuzz(secs, card: card)
            return Outcome(label: buttonTime(seconds: secs, collapse: ctx.collapse), revlogIvl: -secs)
        case .days(let days):
            card.queue = 3
            card.due = ctx.day + days
            return Outcome(label: buttonTime(seconds: days * 86_400, collapse: ctx.collapse), revlogIvl: days)
        }
    }

    private static func graduate(_ card: inout AnkiCard, days requested: Int, ctx: Context) -> Outcome {
        let scheduled = AnkiFuzz.apply(
            factor: ctx.fuzz,
            interval: Double(requested),
            minimum: 1,
            maximum: ctx.maxIvl
        )
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
        AnkiFuzz.apply(
            factor: ctx.fuzz,
            interval: Double(max(scheduled, 1)) * ctx.lapseMult,
            minimum: ctx.lapseMin,
            maximum: ctx.maxIvl
        )
    }

    private static func constrain(_ raw: Double, minimum: Int, ctx: Context) -> Int {
        AnkiFuzz.apply(
            factor: ctx.fuzz,
            interval: raw * ctx.modifier,
            minimum: minimum,
            maximum: ctx.maxIvl
        )
    }

    /// Early reviews are rounded, without the fuzz applied to on-time reviews.
    private static func roundClamped(_ raw: Double, ctx: Context) -> Int {
        let maximum = ctx.maxIvl
        let scaled = raw * ctx.modifier
        return min(maximum, max(1, Int(scaled.rounded())))
    }

    private static func easeFactor(_ card: AnkiCard) -> Double {
        let ease = Double(card.factor) / 1000.0
        return ease >= 1.3 ? ease : 2.5
    }

    private static func storeEase(_ ease: Double) -> Int {
        Int(min(65_535, max(0, (ease * 1000).rounded())))
    }

    /// Nominal learning delay, fuzzed the way Anki fuzzes the stored due time.
    static func fuzzedLearningSeconds(_ seconds: Int, card: AnkiCard) -> Int {
        learningFuzz(seconds, card: card)
    }

    /// Same window as Anki: up to 25% later, and never more than 5 minutes.
    /// The button still shows the nominal delay.
    private static func learningFuzz(_ seconds: Int, card: AnkiCard) -> Int {
        let room = min(Int((Double(seconds) * 0.25).rounded(.down)), 300)
        let upper = seconds + room
        guard upper > seconds else { return max(seconds, 0) }
        let factor = AnkiFuzz.factor(cardID: card.id, reps: card.reps)
        return seconds + Int((Double(upper - seconds) * factor).rounded(.down))
    }

    private static func previousInterval(_ card: AnkiCard, learn: LearningSteps, relearn: LearningSteps) -> Int {
        switch card.type {
        case 2:
            return card.ivl
        case 0:
            return 0
        case 3:
            let secs = relearn.currentDelay(remaining: card.left)
            return secs == 0 ? 0 : -secs
        default:
            let secs = learn.currentDelay(remaining: card.left)
            return secs == 0 ? 0 : -secs
        }
    }

    /// Same shape as Anki's Portuguese answer buttons: `<1min(s)`, `<6min(s)`, `3dia(s)`.
    static func buttonTime(seconds: Int, collapse: Int) -> String {
        if seconds <= 0 { return "(fim)" }
        let text = unitLabel(seconds: seconds)
        if seconds < collapse { return "<\(text)" }
        return text
    }

    private static func unitLabel(seconds: Int) -> String {
        let secs = Double(seconds)
        if secs < 60 {
            return "\(max(Int(secs.rounded()), seconds == 0 ? 0 : 1))s"
        }
        if secs < 3_600 {
            return "\(max(Int((secs / 60).rounded()), 1))min(s)"
        }
        if secs < 86_400 {
            let hours = (secs / 3_600 * 10).rounded() / 10
            if hours == hours.rounded() { return "\(Int(hours))h" }
            return String(format: "%.1fh", hours)
        }
        let month = 86_400.0 * 365.0 / 12.0
        let year = 86_400.0 * 365.0
        if secs < month {
            return "\(max(Int((secs / 86_400).rounded()), 1))dia(s)"
        }
        if secs < year {
            let months = (secs / month * 10).rounded() / 10
            if months == months.rounded() { return "\(Int(months))mês(es)" }
            return String(format: "%.1fmês(es)", months)
        }
        let years = (secs / year * 10).rounded() / 10
        if years == years.rounded() { return "\(Int(years))a" }
        return String(format: "%.1fa", years)
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
        return Int(minutes[index] * 60.0)
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
        return Int((Double(secs) / 86_400.0).rounded()) * 86_400
    }
}

/// Anki's review-interval fuzz. The width of the window matches `rslib`; the position inside it is stable per card.
enum AnkiFuzz {
    static func factor(cardID: Int64, reps: Int) -> Double {
        var state = UInt64(bitPattern: cardID) &+ UInt64(reps)
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        state ^= state >> 33
        return Double(state % 1_000_000) / 1_000_000.0
    }

    static func preservedMinimum(interval: Double, previous: Int, maximum: Int) -> Int {
        let rounded = Int(interval.rounded())
        let upper = constrainedBounds(interval: interval, minimum: 1, maximum: maximum).1
        if rounded > previous { return previous + 1 }
        if previous <= upper { return previous }
        return 0
    }

    static func apply(factor: Double?, interval: Double, minimum: Int, maximum: Int) -> Int {
        let maximum = max(maximum, 1)
        let minimum = min(max(minimum, 1), maximum)
        guard let factor else {
            return min(maximum, max(minimum, Int(interval.rounded())))
        }
        let (lower, upper) = constrainedBounds(interval: interval, minimum: minimum, maximum: maximum)
        let picked = Double(lower) + factor * Double(1 + upper - lower)
        return min(maximum, max(minimum, Int(picked.rounded(.down))))
    }

    private static func constrainedBounds(interval: Double, minimum: Int, maximum: Int) -> (Int, Int) {
        let clamped = min(max(interval, Double(minimum)), Double(maximum))
        var lower = Int((clamped - delta(clamped)).rounded())
        var upper = Int((clamped + delta(clamped)).rounded())
        lower = min(max(lower, minimum), maximum)
        upper = min(max(upper, minimum), maximum)
        if upper == lower, upper > 2, upper < maximum { upper = lower + 1 }
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
