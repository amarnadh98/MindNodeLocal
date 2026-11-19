import Foundation

/// The four answer qualities of a review (FSRS grades 1–4).
public enum Grade: String, Sendable, CaseIterable, Codable {
    case again
    case hard
    case good
    case easy

    /// The numeric grade used by the FSRS formulas (again = 1 … easy = 4).
    public var value: Int {
        switch self {
        case .again: 1
        case .hard: 2
        case .good: 3
        case .easy: 4
        }
    }

    /// Grades in ascending order of recall confidence.
    public static let ascending: [Grade] = [.again, .hard, .good, .easy]
}

/// The FSRS-6 memory model: the pure math of stability and difficulty,
/// ported line-for-line from the reference implementation
/// (`ts-fsrs` 6.0.0, `src/models/fsrs-6/algorithm.ts`, which follows the
/// parameterisation of `py-fsrs` / the FSRS-6 algorithm spec).
///
/// FSRS-6 trains its decay exponent as `w[20]`, so the forgetting curve's
/// factor is derived from the decay such that retrievability equals the
/// desired retention (0.9) exactly one stability interval after the last
/// review — not the FSRS-4.5 constant 19/81.
public struct FSRSModel: Sendable {
    /// The default FSRS-6 weights `w[0…20]` (w[20] is the decay, 0.1542).
    public static let defaultWeights: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
        1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
        1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]

    /// Model bounds, identical to the reference (`FSRS6_MODEL_BOUNDS`).
    public static let stabilityMin: Double = 0.001
    public static let stabilityMax: Double = 36500
    public static let difficultyMin: Double = 1
    public static let difficultyMax: Double = 10

    public let weights: [Double]
    public let enableShortTerm: Bool

    public init(weights: [Double] = FSRSModel.defaultWeights, enableShortTerm: Bool = true) {
        precondition(weights.count == 21, "FSRS-6 requires exactly 21 weights, got \(weights.count)")
        self.weights = weights
        self.enableShortTerm = enableShortTerm
    }

    /// The forgetting-curve decay exponent: `-w[20]`.
    public var decay: Double { -weights[20] }

    /// The forgetting-curve factor, `0.9^(1/decay) - 1` rounded to 8 decimals
    /// (so that R(t = S, S) = 0.9 exactly for the default weights).
    public var factor: Double { roundTo(exp(decay.pow(-1) * log(0.9)) - 1, decimals: 8) }

    // MARK: - Core formulas

    /// Initial stability for the first review of a card (clamped to the model bounds).
    public func initStability(_ grade: Grade) -> Double {
        clamp(weights[grade.value - 1], FSRSModel.stabilityMin, FSRSModel.stabilityMax)
    }

    /// Initial difficulty for the first review of a card, unclamped
    /// (`w4 - e^((g-1)·w5) + 1`); the memory-state step clamps the result to [1, 10].
    public func initDifficulty(_ grade: Grade) -> Double {
        roundTo(weights[4] - exp(Double(grade.value - 1) * weights[5]) + 1, decimals: 8)
    }

    /// Next difficulty with linear damping and mean reversion towards the
    /// easy-rating difficulty (SPEC §10).
    public func nextDifficulty(_ difficulty: Double, _ grade: Grade) -> Double {
        let deltaD = -weights[6] * Double(grade.value - 3)
        let damped = difficulty + linearDamping(deltaD: deltaD, oldDifficulty: difficulty)
        return clamp(meanReversion(initDifficulty(.easy), damped), FSRSModel.difficultyMin, FSRSModel.difficultyMax)
    }

    /// Retrievability — the predicted probability of recall `elapsedDays`
    /// after the last review for a memory of stability `S` (FSRS-6 decay parameter).
    public func retrievability(elapsedDays: Double, stability: Double) -> Double {
        precondition(stability > 0, "retrievability requires a positive stability")
        return roundTo(pow(1 + factor * elapsedDays / stability, decay), decimals: 8)
    }

    /// Stability after a successful recall (`hard`/`good`/`easy`), with the
    /// hard penalty `w15` and easy bonus `w16`.
    public func nextRecallStability(difficulty: Double, stability: Double, retrievability: Double, grade: Grade)
        -> Double
    {
        let hardPenalty: Double = grade == .hard ? weights[15] : 1
        let easyBonus: Double = grade == .easy ? weights[16] : 1
        let challenge = exp((1 - retrievability) * weights[10]) - 1
        let growth = exp(weights[8]) * (11 - difficulty) * stability.pow(-weights[9])
        let next = stability * (1 + growth * challenge * hardPenalty * easyBonus)
        return roundTo(clamp(next, FSRSModel.stabilityMin, FSRSModel.stabilityMax), decimals: 8)
    }

    /// Stability after a lapse, capped at `S / e^(w17·w18)` (the short-term floor).
    public func nextForgetStability(difficulty: Double, stability: Double, retrievability: Double) -> Double {
        let next =
            weights[11] * difficulty.pow(-weights[12])
            * (pow(stability + 1, weights[13]) - 1)
            * exp((1 - retrievability) * weights[14])
        return roundTo(clamp(next, FSRSModel.stabilityMin, FSRSModel.stabilityMax), decimals: 8)
    }

    /// Stability after a same-day review (t = 0): a multiplicative increase
    /// `Sinc = S^-w19 · e^(w17·(g-3+w18))`, masked to never decrease below 1
    /// for `hard` and above.
    public func nextShortTermStability(stability: Double, grade: Grade) -> Double {
        let gradeOffset = Double(grade.value - 3)
        let sinc = stability.pow(-weights[19]) * exp(weights[17] * (gradeOffset + weights[18]))
        let masked = grade.value >= Grade.hard.value ? max(sinc, 1) : sinc
        return roundTo(clamp(stability * masked, FSRSModel.stabilityMin, FSRSModel.stabilityMax), decimals: 8)
    }

    /// The interval (whole days) that keeps retrievability at `desiredRetention`
    /// for stability `S`, at least one day. Maximum-interval capping happens in
    /// the scheduler, as in the reference.
    public func nextInterval(stability: Double, desiredRetention: Double) -> Double {
        precondition(desiredRetention > 0 && desiredRetention <= 1, "desired retention must be in (0, 1]")
        let interval = stability / factor * (pow(desiredRetention, 1 / decay) - 1)
        return max(jsRound(interval), 1)
    }

    // MARK: - Memory-state step

    /// The next `(difficulty, stability)` memory state after reviewing with
    /// `grade` `elapsedDays` whole days after the previous review, mirroring the
    /// reference `next_state`:
    ///
    /// - a fresh card (`d == 0 && s == 0`) initialises;
    /// - a same-day review (`t == 0`, short-term enabled) uses the short-term
    ///   stability rule for every grade;
    /// - otherwise `again` takes the forget path (capped), and the other grades
    ///   the recall path, with `retrievability` computed when not supplied.
    public func nextMemoryState(
        difficulty: Double,
        stability: Double,
        elapsedDays: Double,
        grade: Grade,
        retrievability: Double? = nil
    ) -> (difficulty: Double, stability: Double) {
        precondition(elapsedDays >= 0, "elapsed days must not be negative")
        if difficulty == 0 && stability == 0 {
            return (
                clamp(initDifficulty(grade), FSRSModel.difficultyMin, FSRSModel.difficultyMax), initStability(grade)
            )
        }
        precondition(
            difficulty >= FSRSModel.difficultyMin && stability >= FSRSModel.stabilityMin, "invalid memory state"
        )
        let recall = retrievability ?? self.retrievability(elapsedDays: elapsedDays, stability: stability)
        let nextS: Double
        if elapsedDays == 0 && enableShortTerm {
            nextS = nextShortTermStability(stability: stability, grade: grade)
        } else if grade == .again {
            let afterFail = nextForgetStability(
                difficulty: difficulty, stability: stability, retrievability: recall
            )
            let shortTermFloor =
                enableShortTerm ? roundTo(stability / exp(weights[17] * weights[18]), decimals: 8) : stability
            nextS = clamp(shortTermFloor, FSRSModel.stabilityMin, afterFail)
        } else {
            nextS = nextRecallStability(
                difficulty: difficulty, stability: stability, retrievability: recall, grade: grade
            )
        }
        return (nextDifficulty(difficulty, grade), nextS)
    }

    // MARK: - Private pieces

    private func linearDamping(deltaD: Double, oldDifficulty: Double) -> Double {
        roundTo(deltaD * (10 - oldDifficulty) / 9, decimals: 8)
    }

    private func meanReversion(_ initial: Double, _ current: Double) -> Double {
        roundTo(weights[7] * initial + (1 - weights[7]) * current, decimals: 8)
    }
}

// MARK: - Reference arithmetic helpers

/// `min(max(value, lower), upper)` — the reference `clamp`.
func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
}

/// Rounds half away from zero at `decimals` places, like the reference `roundTo`.
func roundTo(_ value: Double, decimals: Int) -> Double {
    let scale = pow(10, Double(decimals))
    return jsRound(value * scale) / scale
}

/// JavaScript `Math.round` (half up, towards +∞), which the reference uses.
func jsRound(_ value: Double) -> Double {
    floor(value + 0.5)
}

extension Double {
    /// `pow(self, exponent)` with the argument order of the reference formulas.
    func pow(_ exponent: Double) -> Double {
        Foundation.pow(self, exponent)
    }
}
