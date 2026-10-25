import CryptoKit
import Foundation

enum QuestionBankError: Error {
    case missingBundle
    case corruptBundle
}

/// The bundled question set. Stored encrypted (AES-GCM) so answers are not in
/// plain text inside the app; decrypted in memory on launch.
final class QuestionBank {
    let questions: [Question]
    let verifiedOn: String
    private let byCategory: [TriviaCategory: [Question]]

    init(questions: [Question], verifiedOn: String = "") {
        self.questions = questions
        self.verifiedOn = verifiedOn
        self.byCategory = Dictionary(grouping: questions, by: \.category)
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> QuestionBank {
        guard let url = bundle.url(forResource: "questions", withExtension: "bin") else {
            throw QuestionBankError.missingBundle
        }
        return try decode(encrypted: Data(contentsOf: url))
    }

    static func decode(encrypted data: Data) throws -> QuestionBank {
        struct File: Decodable {
            let v: Int
            let verified_on: String
            let q: [Question]
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: BundleKey.bytes),
                                         authenticating: BundleKey.associatedData)
            let file = try JSONDecoder().decode(File.self, from: plain)
            return QuestionBank(questions: file.q, verifiedOn: file.verified_on)
        } catch {
            throw QuestionBankError.corruptBundle
        }
    }

    func count(in category: TriviaCategory, difficulty: DifficultyFilter = .mixed) -> Int {
        (byCategory[category] ?? []).filter { difficulty.matches($0.difficulty) }.count
    }

    func available(for settings: MatchSettings) -> Int {
        let cats = settings.categories.isEmpty ? TriviaCategory.allCases : settings.categories
        return cats.reduce(0) { $0 + count(in: $1, difficulty: settings.difficulty) }
    }

    /// Picks `count` questions matching the settings. Questions nobody in the
    /// match has seen come first; categories are interleaved so a mixed match
    /// does not cluster on one topic.
    func pick<G: RandomNumberGenerator>(settings: MatchSettings, seen: Set<String>, count: Int,
                                        using rng: inout G) -> [Question] {
        let cats = settings.categories.isEmpty ? TriviaCategory.allCases : settings.categories
        var fresh: [[Question]] = []
        var stale: [Question] = []
        for cat in cats.shuffled(using: &rng) {
            let pool = (byCategory[cat] ?? []).filter { settings.difficulty.matches($0.difficulty) }
            fresh.append(pool.filter { !seen.contains($0.id) }.shuffled(using: &rng))
            stale.append(contentsOf: pool.filter { seen.contains($0.id) })
        }
        var result: [Question] = []
        var index = 0
        while result.count < count && fresh.contains(where: { index < $0.count }) {
            for list in fresh where index < list.count && result.count < count {
                result.append(list[index])
            }
            index += 1
        }
        if result.count < count {
            result.append(contentsOf: stale.shuffled(using: &rng).prefix(count - result.count))
        }
        return result.shuffled(using: &rng)
    }

    func pick(settings: MatchSettings, seen: Set<String>, count: Int) -> [Question] {
        var rng = SystemRandomNumberGenerator()
        return pick(settings: settings, seen: seen, count: count, using: &rng)
    }
}
