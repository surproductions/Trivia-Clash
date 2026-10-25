import Foundation

// MARK: - Catalogue

enum TriviaCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case general, science, history, geography, sports, screen, music, games
    case tech, food, arts, animals, space, mythology, popculture, math

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General Knowledge"
        case .science: return "Science & Nature"
        case .history: return "History"
        case .geography: return "Geography"
        case .sports: return "Sports"
        case .screen: return "Movies & TV"
        case .music: return "Music"
        case .games: return "Video Games"
        case .tech: return "Technology"
        case .food: return "Food & Drink"
        case .arts: return "Art & Literature"
        case .animals: return "Animals"
        case .space: return "Space"
        case .mythology: return "Mythology"
        case .popculture: return "Pop Culture"
        case .math: return "Maths & Logic"
        }
    }

    var shortTitle: String {
        switch self {
        case .general: return "General"
        case .science: return "Science"
        case .screen: return "Screen"
        case .games: return "Games"
        case .food: return "Food"
        case .arts: return "Arts"
        case .popculture: return "Pop"
        case .math: return "Maths"
        default: return title
        }
    }

    /// SF Symbol used for the category tile.
    var symbol: String {
        switch self {
        case .general: return "lightbulb.max"
        case .science: return "atom"
        case .history: return "building.columns"
        case .geography: return "globe.europe.africa"
        case .sports: return "figure.run"
        case .screen: return "film"
        case .music: return "music.note"
        case .games: return "gamecontroller"
        case .tech: return "cpu"
        case .food: return "fork.knife"
        case .arts: return "paintpalette"
        case .animals: return "pawprint"
        case .space: return "moon.stars"
        case .mythology: return "bolt"
        case .popculture: return "sparkles"
        case .math: return "function"
        }
    }
}

enum Difficulty: String, Codable, CaseIterable, Identifiable {
    case easy, medium, hard
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Difficulty filter chosen in match settings.
enum DifficultyFilter: String, Codable, CaseIterable, Identifiable {
    case mixed, easy, medium, hard
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func matches(_ d: Difficulty) -> Bool {
        switch self {
        case .mixed: return true
        case .easy: return d == .easy
        case .medium: return d == .medium
        case .hard: return d == .hard
        }
    }
}

/// A question as stored in the (encrypted) bundle. `answer` never leaves the
/// device that hosts the match.
struct Question: Codable, Identifiable, Hashable {
    let id: String
    let category: TriviaCategory
    let difficulty: Difficulty
    let prompt: String
    let options: [String]
    let answer: Int
    let explanation: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, category = "c", difficulty = "d", prompt = "p", options = "o", answer = "a", explanation = "e", source = "s"
    }
}

// MARK: - Match configuration

enum GameMode: String, Codable, CaseIterable, Identifiable {
    case solo, ffa, teams
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solo: return "Solo"
        case .ffa: return "Free-for-All"
        case .teams: return "Team Battle"
        }
    }
}

struct MatchSettings: Codable, Equatable {
    var questionCount: Int = 10
    /// Empty means every category.
    var categories: [TriviaCategory] = []
    var difficulty: DifficultyFilter = .mixed
    var teamCount: Int = 2
    var finalDouble: Bool = false

    static let soloLengths = [10, 20, 30]
    static let partyLengths = [5, 10, 15, 20]

    func sanitized(for mode: GameMode) -> MatchSettings {
        var s = self
        let allowed = mode == .solo ? MatchSettings.soloLengths : MatchSettings.partyLengths
        if !allowed.contains(s.questionCount) { s.questionCount = 10 }
        s.categories = Array(Set(s.categories)).sorted { $0.rawValue < $1.rawValue }
        s.teamCount = min(max(s.teamCount, 2), 4)
        return s
    }
}

enum Phase: String, Codable {
    case lobby, countdown, question, reveal, finished, closed
}

// MARK: - The per-player view of a match
//
// This is the only thing a non-host device ever receives. Before a round closes
// it contains the question and that player's own option order, never the answer.

struct PlayerView: Codable, Equatable {
    var serverNow: Int64
    var version: Int
    var me: String
    var room: RoomInfo
    var members: [MemberView]
    var teams: [TeamView]?
    var round: RoundView?
    var reveal: RevealView?
}

struct RoomInfo: Codable, Equatable {
    var id: String
    var code: String
    var mode: GameMode
    var status: Phase
    var hostId: String?
    var questionCount: Int
    var totalRounds: Int
    var categories: [TriviaCategory]
    var difficulty: DifficultyFilter
    var teamCount: Int
    var finalDouble: Bool
    var matchNo: Int
    var currentRound: Int
    var phaseEndsAt: Int64?
    var maxPlayers: Int

    var settings: MatchSettings {
        MatchSettings(questionCount: questionCount, categories: categories, difficulty: difficulty,
                      teamCount: teamCount, finalDouble: finalDouble)
    }
}

struct MemberView: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var avatar: Int
    var team: Int?
    var ready: Bool
    var host: Bool
    var connected: Bool
    var left: Bool
    var score: Int
    var correct: Int
    var answered: Int
    var streak: Int
    var bestStreak: Int
    var fastestMs: Int?
    var avgMs: Int?
    var lastPoints: Int
    var lastCorrect: Bool?
    var rank: Int
    var lockedIn: Bool
}

struct TeamView: Codable, Equatable, Identifiable {
    var index: Int
    var size: Int
    var score: Int
    var total: Int
    var correct: Int
    var rank: Int
    var id: Int { index }
}

struct RoundView: Codable, Equatable {
    var no: Int
    var total: Int
    var category: TriviaCategory
    var difficulty: Difficulty
    var prompt: String
    var options: [String]
    var opensAt: Int64
    var closesAt: Int64
    var multiplier: Int
    var answeredCount: Int
    var myChoice: Int?
    var closed: Bool
}

struct RevealView: Codable, Equatable {
    var correctChoice: Int
    var explanation: String
    var source: String
    var my: AnswerResult?
    var distribution: [Int]
}

struct AnswerResult: Codable, Equatable {
    var correct: Bool
    var points: Int
    var base: Int
    var speed: Int
    var streakBonus: Int
    var responseMs: Int
}

enum SubmitStatus: String, Codable {
    case accepted
    case alreadyAnswered = "already_answered"
    case tooLate = "too_late"
    case notActive = "not_active"
}

struct SubmitOutcome: Codable, Equatable {
    var status: SubmitStatus
    var choice: Int?
}

// MARK: - Team presentation

enum TeamStyle {
    static let names = ["Volt", "Ember", "Tide", "Bloom"]
    static func name(_ index: Int) -> String { names[index % names.count] }
}
