import Foundation
@testable import TriviaClash

enum Fixtures {
    static func question(_ n: Int, category: TriviaCategory = .general, difficulty: Difficulty = .easy, answer: Int = 0) -> Question {
        Question(id: "q\(n)", category: category, difficulty: difficulty, prompt: "Question number \(n)?",
                 options: ["A\(n)", "B\(n)", "C\(n)", "D\(n)"], answer: answer,
                 explanation: "Because \(n).", source: "https://example.com/\(n)")
    }

    static func bank(_ count: Int = 40) -> QuestionBank {
        let cats = TriviaCategory.allCases
        let diffs = Difficulty.allCases
        return QuestionBank(questions: (0..<count).map {
            question($0, category: cats[$0 % cats.count], difficulty: diffs[$0 % diffs.count], answer: $0 % 4)
        })
    }

    /// An engine with deterministic questions (answer index = round % 4).
    static func engine(mode: GameMode = .ffa, settings: MatchSettings = MatchSettings(questionCount: 5),
                       questions: [Question]? = nil) -> MatchEngine {
        let qs = questions ?? (0..<30).map { question($0, answer: $0 % 4) }
        return MatchEngine(mode: mode, settings: settings, code: "ABCDE", seed: 42) { _, seen, count in
            Array(qs.filter { !seen.contains($0.id) }.prefix(count))
        }
    }
}

extension MatchEngine {
    /// The display position that shows the correct answer to `playerId` in the current round.
    func correctChoice(for playerId: String) -> Int {
        let round = rounds[currentRound - 1]
        let perm = AnswerOrder.permutation(seed: round.seed, playerId: playerId)
        return perm.firstIndex(of: round.question.answer)!
    }

    func wrongChoice(for playerId: String) -> Int { (correctChoice(for: playerId) + 1) % 4 }

    /// Joins `ids` (first is host), readies everyone and starts at t=0; returns the time round 1 opens.
    @discardableResult
    func startStandard(_ ids: [String], now: Int64 = 0) throws -> Int64 {
        for id in ids { try join(id: id, name: id, avatar: 0, now: now) }
        for id in ids.dropFirst() { try setReady(id, true) }
        try start(by: ids[0], now: now)
        let open = now + timing.countdownMs
        tick(now: open)
        return open
    }
}
