import SwiftUI
import UIKit

final class AppState: ObservableObject {
    @Published var profile: Profile?
    @Published var preferences: Preferences {
        didSet {
            store.preferences = preferences
            applyPreferences()
        }
    }
    @Published private(set) var stats: SoloStats
    @Published private(set) var bank: QuestionBank?
    @Published private(set) var bankError: String?
    @Published var session: GameSession?
    /// A room code received from a QR code / invite link, consumed by the Join screen.
    @Published var pendingJoinCode: String?
    @Published var showJoin = false

    let store: LocalStore
    private var recordedMatches = Set<String>()

    init(store: LocalStore = .shared) {
        self.store = store
        profile = store.profile
        preferences = store.preferences
        stats = store.stats
        applyPreferences()
        loadBank()
    }

    private func applyPreferences() {
        SoundPlayer.shared.enabled = preferences.soundOn
        Haptics.enabled = preferences.hapticsOn
    }

    func loadBank() {
        bankError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try QuestionBank.loadBundled() }
            DispatchQueue.main.async {
                switch result {
                case .success(let bank): self.bank = bank
                case .failure: self.bankError = "The question bank couldn't be loaded. Reinstalling the app should fix this."
                }
            }
        }
    }

    // MARK: Profile

    func saveProfile(name: String, avatar: Int) {
        let clean = Profile.clean(name)
        let updated = Profile(id: profile?.id ?? UUID().uuidString, name: clean, avatar: avatar)
        profile = updated
        store.profile = updated
    }

    func resetAllData() {
        session?.leave()
        session = nil
        store.eraseAll()
        profile = nil
        preferences = Preferences()
        stats = SoloStats()
    }

    // MARK: Sessions

    var seenSet: Set<String> { Set(store.seenQuestions) }

    func startSolo(settings: MatchSettings) {
        guard let profile, let bank else { return }
        store.lastSoloSettings = settings
        session = SoloSession(profile: profile, settings: settings, bank: bank, seen: seenSet)
    }

    func host(mode: GameMode, settings: MatchSettings) {
        guard let profile, let bank else { return }
        store.lastPartySettings = settings
        session = NearbyHostSession(profile: profile, mode: mode, settings: settings, bank: bank, seen: seenSet)
    }

    func join(room: NearbyRoom, browser: NearbyBrowser) {
        guard let profile else { return }
        session = NearbyGuestSession(profile: profile, room: room, transport: browser.transport,
                                     seen: Array(store.seenQuestions.suffix(300)))
    }

    func endSession() {
        session?.leave()
        session = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Records a finished match once (local stats only; nothing is uploaded).
    func record(finished view: PlayerView, session: GameSession) {
        let key = "\(view.room.id)#\(view.room.matchNo)"
        guard view.room.status == .finished, !recordedMatches.contains(key),
              let me = view.members.first(where: { $0.id == view.me }) else { return }
        recordedMatches.insert(key)
        var s = stats
        if view.room.mode == .solo {
            s.gamesPlayed += 1
            s.questionsAnswered += view.room.totalRounds
            s.correctAnswers += me.correct
            s.bestStreak = max(s.bestStreak, me.bestStreak)
            let k = "\(view.room.totalRounds)"
            s.bestScores[k] = max(s.bestScores[k] ?? 0, me.score)
        } else {
            s.multiplayerGames += 1
            s.questionsAnswered += view.room.totalRounds
            s.correctAnswers += me.correct
            s.bestStreak = max(s.bestStreak, me.bestStreak)
            let won: Bool
            if view.room.mode == .teams, let team = me.team {
                won = view.teams?.first(where: { $0.index == team })?.rank == 1
            } else {
                won = me.rank == 1
            }
            if won { s.multiplayerWins += 1 }
        }
        stats = s
        store.stats = s
        if let engineSession = session as? EngineSession {
            store.markSeen(engineSession.engine.rounds.filter { $0.opensAt != nil }.map(\.question.id))
        }
    }

    func resetStats() {
        stats = SoloStats()
        store.stats = stats
    }

    // MARK: Deep links

    /// Handles `triviaclash://join?code=ABCDE` (encoded in the lobby QR code).
    func handle(url: URL) {
        guard url.scheme == "triviaclash",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else { return }
        let normalized = RoomCode.normalize(code)
        guard RoomCode.isValid(normalized), session == nil else { return }
        pendingJoinCode = normalized
        showJoin = true
    }
}
