import Foundation

struct FSRSTrainingReview: Codable, Sendable {
    var rating: Int
    var deltaT: Int
}

struct FSRSTrainingItem: Codable, Sendable {
    var cardID: Int64
    var reviews: [FSRSTrainingReview]
}

struct FSRSSimulationCard: Codable, Sendable {
    var id: Int64
    var difficulty: Float
    var stability: Float
    var lastDate: Float?
    var due: Float
    var interval: Float
    var lapses: UInt32
    var desiredRetention: Float
}

struct FSRSSimulationReview: Codable, Sendable {
    var id: Int64
    var cid: Int64
    var usn: Int32
    var buttonChosen: UInt8
    var interval: Int32
    var lastInterval: Int32
    var easeFactor: UInt32
    var takenMillis: UInt32
    var reviewKind: UInt8
}

struct FSRSSimulationRequest: Codable, Sendable {
    var parameters: [Float]
    var retention: Float
    var dayCutoff: Int64
    var deckSize: Int
    var days: Int
    var newPerDay: Int
    var maxReviewsPerDay: Int
    var newCardsIgnoreReviewLimit: Bool
    var maxInterval: Float
    var learningStepCount: Int
    var relearningStepCount: Int
    var cards: [FSRSSimulationCard]
    var revlogs: [FSRSSimulationReview]
}

struct FSRSSimulationDay: Codable, Sendable {
    var day: Int
    var reviews: Int
    var learned: Int
    var studySeconds: Float
    var memorized: Float
}

/// FSRS-6, matching `fsrs-rs` 6.6.2 (`next_states`) and the way Anki applies those intervals.
enum FSRS6 {
    static let defaultDecay: Float = 0.1542
    static let fsrs5Decay: Float = 0.5
    static let defaultParameters: [Float] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
        1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
        1.8729, 0.5425, 0.0912, 0.0658, defaultDecay
    ]

    static let stabilityMin: Float = 0.001
    static let stabilityMax: Float = 36500
    static let difficultyMin: Float = 1
    static let difficultyMax: Float = 10

    struct Memory: Sendable {
        var stability: Float
        var difficulty: Float
    }

    /// The four button states Anki stores in `StateContext.fsrs_next_states`.
    static func forecast(
        card: AnkiCard,
        weights: [Double]?,
        desiredRetention: Double,
        historicalRetention: Double = 0.9,
        daysElapsed: Int,
        reviewedAt: Int,
        shortTermWithSteps: Bool
    ) -> FSRSForecast {
        let parameters = filledParameters(weights)
        let decay = parameters[20]
        let retention = Float(min(max(desiredRetention, 0.7), 0.99))
        let memory = currentMemory(
            card: card,
            parameters: parameters,
            historicalRetention: Float(min(max(historicalRetention, 0.7), 0.99))
        )
        let states = nextStates(memory: memory, parameters: parameters, desiredRetention: retention, daysElapsed: max(daysElapsed, 0))
        let allowShortTerm = parameters[17] > 0 && parameters[18] > 0
        return FSRSForecast(
            again: states.0, hard: states.1, good: states.2, easy: states.3,
            allowShortTerm: allowShortTerm,
            shortTermWithSteps: shortTermWithSteps,
            decay: decay,
            desiredRetention: retention,
            reviewedAt: reviewedAt
        )
    }

    static func memoryState(
        reviews: [AnkiRevlog],
        weights: [Double]?,
        nextDayAt: Int64,
        historicalRetention: Float,
        ignoreBefore: Int64?
    ) -> Memory? {
        let activeReviews = reviewsAfterLastReset(reviews)
        let included = activeReviews
            .filter { $0.ease >= 1 && $0.ease <= 4 && $0.type != 4 }
        guard !included.isEmpty else { return nil }

        let cutoff = ignoreBefore.map { $0 > 0 ? $0 * 1000 : 0 } ?? 0
        let filtered = included.filter { $0.id >= cutoff }
        guard !filtered.isEmpty else { return nil }

        let parameters = filledParameters(weights)
        let hasLearningHistory = filtered.first?.type == 0
        var state: Memory?
        var previousDay: Int?
        var reviewsToProcess = filtered

        if !hasLearningHistory, let first = filtered.first {
            let interval = Float(max(first.ivl, 1))
            let ease = Float(first.factor > 0 ? first.factor : 2500) / 1000
            state = memoryFromSM2(
                ease: ease >= 1.3 ? ease : 2.5,
                interval: interval,
                retention: historicalRetention,
                parameters: parameters
            )
            if ease <= 1.1, var inferred = state {
                inferred.difficulty = min(max((ease - 0.1) * 9 + 1, difficultyMin), difficultyMax)
                state = inferred
            }
            previousDay = schedulingDay(
                timestamp: first.id / 1000,
                nextDayAt: nextDayAt
            )
            reviewsToProcess.removeFirst()
        }

        for review in reviewsToProcess {
            let currentDay = schedulingDay(
                timestamp: review.id / 1000,
                nextDayAt: nextDayAt
            )
            let delta = max(0, (previousDay ?? currentDay) - currentDay)
            state = step(
                parameters,
                deltaT: Float(delta),
                rating: Float(review.ease),
                state: state ?? Memory(stability: 0, difficulty: 0),
                nth: state == nil ? 0 : 1
            )
            previousDay = currentDay
        }
        return state
    }

    static func reviewsAfterLastReset(_ reviews: [AnkiRevlog]) -> [AnkiRevlog] {
        let ordered = reviews.sorted { $0.id < $1.id }
        guard let reset = ordered.lastIndex(where: { $0.type == 4 && $0.ease == 0 && $0.ivl == 0 }) else {
            return ordered
        }
        return Array(ordered.suffix(from: ordered.index(after: reset)))
    }

    static func nextInterval(stability: Float, desiredRetention: Float, parameters: [Float]) -> Float {
        nextInterval(parameters, stability: stability, desiredRetention: desiredRetention)
    }

    private static func schedulingDay(timestamp: Int64, nextDayAt: Int64) -> Int {
        Int(max(0, nextDayAt - timestamp) / 86_400)
    }

    static func shiftedDifficulty(_ difficulty: Float) -> Float {
        ((difficulty - 1) / 9) + 0.1
    }

    static func retrievability(daysElapsed: Float, stability: Float, decay: Float) -> Float {
        let power = -abs(decay)
        let factor = exp(log(Float(0.9)) / power) - 1
        return pow(daysElapsed / max(stability, stabilityMin) * factor + 1, power)
    }

    // MARK: - Algorithm

    static func nextStates(
        memory: Memory?,
        parameters: [Float],
        desiredRetention: Float,
        daysElapsed: Int
    ) -> (FSRSForecast.Item, FSRSForecast.Item, FSRSForecast.Item, FSRSForecast.Item) {
        let current = memory ?? Memory(stability: 0, difficulty: 0)
        let nth = memory == nil ? 0 : 1
        func item(_ rating: Int) -> FSRSForecast.Item {
            let next = step(parameters, deltaT: Float(daysElapsed), rating: Float(rating), state: current, nth: nth)
            let interval = nextInterval(parameters, stability: next.stability, desiredRetention: desiredRetention)
            return FSRSForecast.Item(stability: next.stability, difficulty: next.difficulty, interval: interval)
        }
        return (item(1), item(2), item(3), item(4))
    }

    private static func step(_ w: [Float], deltaT: Float, rating: Float, state: Memory, nth: Int) -> Memory {
        let lastS = min(max(state.stability, stabilityMin), stabilityMax)
        let lastD = min(max(state.difficulty, difficultyMin), difficultyMax)
        let retrievability = forgettingCurve(w, t: deltaT, s: lastS)
        var newS = rating == 1
            ? stabilityAfterFailure(w, lastS: lastS, lastD: lastD, r: retrievability)
            : stabilityAfterSuccess(w, lastS: lastS, lastD: lastD, r: retrievability, rating: rating)
        if deltaT == 0 {
            newS = stabilityShortTerm(w, lastS: lastS, rating: rating)
        }
        var newD = meanReversion(w, newD: nextDifficulty(w, difficulty: lastD, rating: rating))
        newD = min(max(newD, difficultyMin), difficultyMax)
        if nth == 0, state.stability == 0 {
            let initRating = min(max(Int(rating), 1), 4)
            newS = initStability(w, rating: initRating)
            newD = min(max(initDifficulty(w, rating: initRating), difficultyMin), difficultyMax)
        }
        if rating == 0 {
            newS = lastS
            newD = lastD
        }
        return Memory(
            stability: min(max(newS, stabilityMin), stabilityMax),
            difficulty: newD
        )
    }

    private static func forgettingCurve(_ w: [Float], t: Float, s: Float) -> Float {
        let decay = -w[20]
        let factor = exp(log(Float(0.9)) / decay) - 1
        return pow(t / s * factor + 1, decay)
    }

    private static func nextInterval(_ w: [Float], stability: Float, desiredRetention: Float) -> Float {
        let decay = -w[20]
        let factor = exp(log(Float(0.9)) / decay) - 1
        return stability / factor * (pow(desiredRetention, 1 / decay) - 1)
    }

    private static func initStability(_ w: [Float], rating: Int) -> Float {
        w[max(0, min(rating - 1, 3))]
    }

    private static func initDifficulty(_ w: [Float], rating: Int) -> Float {
        w[4] - exp(w[5] * Float(max(rating - 1, 0))) + 1
    }

    private static func meanReversion(_ w: [Float], newD: Float) -> Float {
        w[7] * (initDifficulty(w, rating: 4) - newD) + newD
    }

    private static func nextDifficulty(_ w: [Float], difficulty: Float, rating: Float) -> Float {
        let delta = -w[6] * (rating - 3)
        return difficulty + (10 - difficulty) * delta / 9
    }

    private static func stabilityAfterSuccess(_ w: [Float], lastS: Float, lastD: Float, r: Float, rating: Float) -> Float {
        let hardPenalty: Float = rating == 2 ? w[15] : 1
        let easyBonus: Float = rating == 4 ? w[16] : 1
        return lastS * (exp(w[8]) * (11 - lastD) * pow(lastS, -w[9]) * (exp((1 - r) * w[10]) - 1) * hardPenalty * easyBonus + 1)
    }

    private static func stabilityAfterFailure(_ w: [Float], lastS: Float, lastD: Float, r: Float) -> Float {
        let newS = w[11] * pow(lastD, -w[12]) * (pow(lastS + 1, w[13]) - 1) * exp((1 - r) * w[14])
        let floor = lastS / exp(w[17] * w[18])
        return min(newS, floor)
    }

    private static func stabilityShortTerm(_ w: [Float], lastS: Float, rating: Float) -> Float {
        let sinc = exp(w[17] * (rating - 3 + w[18])) * pow(lastS, -w[19])
        return lastS * (rating >= 2 ? max(sinc, 1) : sinc)
    }

    /// Approximate a missing memory state from the card's SM-2 ease and interval.
    static func memoryFromSM2(ease: Float, interval: Float, retention: Float, parameters: [Float]) -> Memory {
        let decay = -parameters[20]
        let factor = pow(Float(0.9), 1 / decay) - 1
        let stability = max(interval, stabilityMin) * factor / (pow(retention, 1 / decay) - 1)
        let difficulty = 11 - (ease - 1) / (exp(parameters[8]) * pow(stability, -parameters[9]) * expm1((1 - retention) * parameters[10]))
        return Memory(
            stability: stability,
            difficulty: min(max(difficulty, difficultyMin), difficultyMax)
        )
    }

    static func filledParameters(_ weights: [Double]?) -> [Float] {
        let raw = (weights ?? []).map { Float($0) }
        switch raw.count {
        case 0:
            return defaultParameters
        case 17:
            var parameters = raw
            parameters[4] = parameters[5] * 2 + parameters[4]
            parameters[5] = log(parameters[5] * 3 + 1) / 3
            parameters[6] += 0.5
            parameters.append(contentsOf: [0, 0, 0, fsrs5Decay])
            return parameters.allSatisfy(\.isFinite) ? parameters : defaultParameters
        case 19:
            var parameters = raw
            parameters.append(contentsOf: [0, fsrs5Decay])
            return parameters.allSatisfy(\.isFinite) ? parameters : defaultParameters
        case 21:
            return raw.allSatisfy(\.isFinite) ? raw : defaultParameters
        default:
            return defaultParameters
        }
    }

    private static func currentMemory(card: AnkiCard, parameters: [Float], historicalRetention: Float) -> Memory? {
        if card.type == 0 { return nil }
        if let stored = FSRSCardData.memory(in: card.data) { return stored }
        let ease = Float(card.factor) / 1000
        if card.ivl > 0 {
            return memoryFromSM2(
                ease: ease >= 1.3 ? ease : 2.5,
                interval: Float(card.ivl),
                retention: historicalRetention,
                parameters: parameters
            )
        }
        return nil
    }
}

struct FSRSForecast: Sendable {
    struct Item: Sendable {
        var stability: Float
        var difficulty: Float
        var interval: Float
    }

    var again: Item
    var hard: Item
    var good: Item
    var easy: Item
    var allowShortTerm: Bool
    var shortTermWithSteps: Bool
    var decay: Float
    var desiredRetention: Float
    var reviewedAt: Int

    func item(for rating: Rating) -> Item {
        switch rating {
        case .again: return again
        case .hard: return hard
        case .good: return good
        case .easy: return easy
        }
    }

    /// Intervals under half a day stay in learning when Anki allows short-term scheduling.
    func keepsShortTerm(_ interval: Float, stepsEmpty: Bool) -> Bool {
        allowShortTerm && (shortTermWithSteps || stepsEmpty) && interval < 0.5
    }
}

enum FSRSCardData {
    static func customData(in raw: String) -> String {
        guard let object = object(from: raw) else { return "" }
        return object["cd"] as? String ?? ""
    }

    static func mergingCustomData(_ customData: String, into raw: String) -> String {
        guard isValidCustomData(customData) else { return raw }
        var object = object(from: raw) ?? [:]
        if customData.isEmpty || customData == "{}" {
            object.removeValue(forKey: "cd")
        } else {
            object["cd"] = customData
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    private static func isValidCustomData(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw != "{}" else { return true }
        guard raw.utf8.count <= 100,
              let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return false }
        return object.keys.allSatisfy { $0.utf8.count <= 8 }
    }

    static func memory(in raw: String) -> FSRS6.Memory? {
        guard let object = object(from: raw),
              let stability = number(object["s"]),
              let difficulty = number(object["d"]) else { return nil }
        return FSRS6.Memory(stability: Float(stability), difficulty: Float(difficulty))
    }

    static func lastReview(in raw: String) -> Int? {
        guard let object = object(from: raw) else { return nil }
        return number(object["lrt"]).map { Int($0) }
    }

    static func originalPosition(in raw: String) -> Int? {
        guard let object = object(from: raw) else { return nil }
        return number(object["pos"]).map { Int($0) }
    }

    static func mergingOriginalPosition(_ position: Int, into raw: String) -> String {
        var object = object(from: raw) ?? [:]
        object["pos"] = position
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    /// rslib sets `last_review_time` on every answer except filtered previews.
    static func mergingLastReview(_ timestamp: Int, into raw: String) -> String {
        var object = object(from: raw) ?? [:]
        object["lrt"] = timestamp
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    static func clearingOriginalPosition(in raw: String) -> String {
        var object = object(from: raw) ?? [:]
        object.removeValue(forKey: "pos")
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    static func desiredRetention(in raw: String) -> Float? {
        guard let object = object(from: raw) else { return nil }
        return number(object["dr"]).map(Float.init)
    }

    static func decay(in raw: String) -> Float? {
        guard let object = object(from: raw) else { return nil }
        return number(object["decay"]).map(Float.init)
    }

    static func merging(
        _ raw: String,
        item: FSRSForecast.Item,
        retention: Float,
        decay: Float,
        reviewedAt: Int
    ) -> String {
        var object = object(from: raw) ?? [:]
        object["s"] = rounded(Double(item.stability), places: 4)
        object["d"] = rounded(Double(item.difficulty), places: 3)
        object["dr"] = rounded(Double(retention), places: 2)
        object["decay"] = rounded(Double(decay), places: 3)
        object["lrt"] = reviewedAt
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    static func merging(_ raw: String, memory: [String: Any]) -> String {
        guard let stability = memory["stability"], let difficulty = memory["difficulty"],
              let stabilityValue = number(stability), let difficultyValue = number(difficulty),
              stabilityValue.isFinite, difficultyValue.isFinite else { return raw }
        var object = object(from: raw) ?? [:]
        object["s"] = rounded(stabilityValue, places: 4)
        object["d"] = rounded(difficultyValue, places: 3)
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    static func replacingMemory(
        in raw: String,
        with memory: FSRS6.Memory?,
        retention: Float,
        decay: Float
    ) -> String {
        var object = object(from: raw) ?? [:]
        if let memory {
            object["s"] = rounded(Double(memory.stability), places: 4)
            object["d"] = rounded(Double(memory.difficulty), places: 3)
        } else {
            object.removeValue(forKey: "s")
            object.removeValue(forKey: "d")
        }
        object["dr"] = rounded(Double(retention), places: 2)
        object["decay"] = rounded(Double(decay), places: 3)
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    static func clearingMemory(in raw: String) -> String {
        var object = object(from: raw) ?? [:]
        object.removeValue(forKey: "s")
        object.removeValue(forKey: "d")
        object.removeValue(forKey: "dr")
        object.removeValue(forKey: "decay")
        object.removeValue(forKey: "lrt")
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    private static func object(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8), !raw.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (value * factor).rounded() / factor
    }
}
