import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// Monotonic milliseconds that keep counting while the device sleeps and are not
/// affected by the user changing the wall clock. All game deadlines use this.
enum Monotonic {
    static func nowMs() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
    }
}

// MARK: - Profile

/// Guest identity. Nothing here leaves the device except the display name and
/// avatar index, which are shown to other players in a nearby match.
struct Profile: Codable, Equatable {
    var id: String
    var name: String
    var avatar: Int

    static let nameRange = 2...16

    static func clean(_ raw: String) -> String {
        let collapsed = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let printable = collapsed.filter { ch in
            !ch.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        return String(printable.prefix(16))
    }

    static func isValid(_ name: String) -> Bool {
        nameRange.contains(clean(name).count) && !NameFilter.isBlocked(clean(name))
    }
}

enum NameFilter {
    private static let blocked = ["fuck", "shit", "cunt", "nigg", "fag", "bitch", "whore", "slut", "rape", "nazi",
                                  "hitler", "kike", "spic", "chink", "retard"]
    static func isBlocked(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return blocked.contains { lowered.contains($0) }
    }
}

enum AppearanceSetting: String, Codable, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

struct Preferences: Codable, Equatable {
    var soundOn = true
    var hapticsOn = true
    var appearance: AppearanceSetting = .system
}

struct SoloStats: Codable, Equatable {
    var gamesPlayed = 0
    var questionsAnswered = 0
    var correctAnswers = 0
    var bestStreak = 0
    /// Best score keyed by question count ("10", "20", "30").
    var bestScores: [String: Int] = [:]
    var multiplayerGames = 0
    var multiplayerWins = 0

    var accuracy: Double { questionsAnswered == 0 ? 0 : Double(correctAnswers) / Double(questionsAnswered) }
}

/// Small persistence layer over UserDefaults. All data stays on the device.
final class LocalStore {
    static let shared = LocalStore()
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? encoder.encode(value) { defaults.set(data, forKey: key) }
    }

    var profile: Profile? {
        get { load("tc.profile", as: Profile.self) }
        set { if let newValue { save(newValue, "tc.profile") } else { defaults.removeObject(forKey: "tc.profile") } }
    }

    var preferences: Preferences {
        get { load("tc.preferences", as: Preferences.self) ?? Preferences() }
        set { save(newValue, "tc.preferences") }
    }

    var stats: SoloStats {
        get { load("tc.stats", as: SoloStats.self) ?? SoloStats() }
        set { save(newValue, "tc.stats") }
    }

    /// Most recently served question ids, newest last (capped).
    var seenQuestions: [String] {
        get { defaults.stringArray(forKey: "tc.seen") ?? [] }
        set { defaults.set(Array(newValue.suffix(2000)), forKey: "tc.seen") }
    }

    func markSeen(_ ids: [String]) {
        var list = seenQuestions.filter { !ids.contains($0) }
        list.append(contentsOf: ids)
        seenQuestions = list
    }

    var lastSoloSettings: MatchSettings {
        get { load("tc.soloSettings", as: MatchSettings.self) ?? MatchSettings() }
        set { save(newValue, "tc.soloSettings") }
    }

    var lastPartySettings: MatchSettings {
        get { load("tc.partySettings", as: MatchSettings.self) ?? MatchSettings() }
        set { save(newValue, "tc.partySettings") }
    }

    func eraseAll() {
        for key in ["tc.profile", "tc.preferences", "tc.stats", "tc.seen", "tc.soloSettings", "tc.partySettings"] {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Feedback

enum SoundEffect: String, CaseIterable {
    case tick, submit, correct, wrong, leaderboard, victory, start
}

/// Plays short bundled effects. Uses the ambient category so the silent switch
/// and other apps' audio are respected; the game is fully playable muted.
final class SoundPlayer {
    static let shared = SoundPlayer()
    var enabled = true
    private var players: [SoundEffect: AVAudioPlayer] = [:]

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        for effect in SoundEffect.allCases {
            if let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "wav"),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                players[effect] = player
            }
        }
    }

    func play(_ effect: SoundEffect) {
        guard enabled, let player = players[effect] else { return }
        player.currentTime = 0
        player.play()
    }
}

enum Haptics {
    static var enabled = true

    static func tap() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func lockIn() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func result(_ correct: Bool) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(correct ? .success : .error)
    }

    static func warning() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
