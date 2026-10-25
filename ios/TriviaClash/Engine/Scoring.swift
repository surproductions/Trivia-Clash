import Foundation

/// Scoring rules (mirrored by `tc_private.score` in the online backend; see docs/SCORING.md).
///
///  * correct answer: 1,000 points
///  * speed bonus:    floor(250 × remainingMs / 10,000), measured by the authority's clock
///  * streak bonus:   50 × (consecutive correct answers before this one), capped at 200
///  * multiplier:     ×2 on the optional final "double points" question
///  * wrong answer or no answer: 0 points, and the streak resets
enum Scoring {
    static let base = 1_000
    static let maxSpeedBonus = 250
    static let streakStep = 50
    static let maxStreakSteps = 4
    static let windowMs: Int64 = 10_000

    struct Breakdown: Equatable {
        var base: Int
        var speed: Int
        var streakBonus: Int
        var total: Int
    }

    static func score(correct: Bool, remainingMs: Int64, streakBefore: Int, multiplier: Int) -> Breakdown {
        guard correct else { return Breakdown(base: 0, speed: 0, streakBonus: 0, total: 0) }
        let remaining = min(max(remainingMs, 0), windowMs)
        let speed = Int((Int64(maxSpeedBonus) * remaining) / windowMs)
        let streak = min(max(streakBefore, 0), maxStreakSteps) * streakStep
        let m = min(max(multiplier, 1), 2)
        return Breakdown(base: base, speed: speed, streakBonus: streak, total: (base + speed + streak) * m)
    }
}

/// Deterministic per-player answer order for a round.
enum AnswerOrder {
    /// Returns `perm` where display position `i` shows original option `perm[i]`.
    static func permutation(seed: UInt64, playerId: String) -> [Int] {
        var generator = SplitMix64(seed: seed ^ fnv1a(playerId))
        var order = [0, 1, 2, 3]
        for i in stride(from: order.count - 1, to: 0, by: -1) {
            let j = Int(generator.next() % UInt64(i + 1))
            order.swapAt(i, j)
        }
        return order
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Room codes: five characters from an alphabet without look-alikes (no O/0, I/1/L).
enum RoomCode {
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 5

    static func generate<G: RandomNumberGenerator>(using rng: inout G) -> String {
        String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
    }

    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    /// Uppercases and keeps only characters that can appear in a code (spaces,
    /// dashes and look-alikes such as O, 0, I, 1 and L are dropped).
    static func normalize(_ input: String) -> String {
        String(input.uppercased().filter { alphabet.contains($0) }.prefix(length))
    }

    static func isValid(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { alphabet.contains($0) }
    }
}
