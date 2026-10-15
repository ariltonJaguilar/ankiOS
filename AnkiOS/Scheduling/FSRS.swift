import Foundation

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
        daysElapsed: Int,
        reviewedAt: Int,
        shortTermWithSteps: Bool
    ) -> FSRSForecast {
        let parameters = filledParameters(weights)
        let decay = parameters[20]
        let retention = Float(min(max(desiredRetention, 0.7), 0.99))
        let memory = currentMemory(card: card, parameters: parameters, retention: retention)
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

    static func shiftedDifficulty(_ difficulty: Float) -> Float {
        ((difficulty - 1) / 9) + 0.1
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

    private static func currentMemory(card: AnkiCard, parameters: [Float], retention: Float) -> Memory? {
        if card.type == 0 { return nil }
        if let stored = FSRSCardData.memory(in: card.data) { return stored }
        let ease = Float(card.factor) / 1000
        if card.ivl > 0 {
            return memoryFromSM2(
                ease: ease >= 1.3 ? ease : 2.5,
                interval: Float(card.ivl),
                retention: retention,
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
