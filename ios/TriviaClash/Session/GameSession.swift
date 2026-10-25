import Foundation
import SwiftUI

enum ConnectionState: Equatable {
    case connecting
    case connected
    case reconnecting
    case lost(String)
}

/// What the UI talks to. Subclasses decide where the authoritative engine lives:
/// on this device (solo, nearby host) or on another phone (nearby guest).
class GameSession: ObservableObject, Identifiable {
    let id = UUID()
    let myId: String

    @Published private(set) var view: PlayerView?
    @Published var connection: ConnectionState = .connected
    @Published var notice: String?
    /// The display position this player tapped, shown immediately while the
    /// authority confirms it.
    @Published var pendingChoice: Int?

    /// Local monotonic time that is mapped to the authority's `view.serverNow`.
    /// It is shifted back by two one-way delays: one for the view that just
    /// arrived and one for an answer travelling back. The local countdown
    /// therefore reaches zero just as a tap could still arrive in time.
    private(set) var anchorLocalMs: Int64 = 0
    /// Estimated one-way delay to the authority (0 for local engines).
    var oneWayLatencyMs: Int64 = 0

    init(myId: String) { self.myId = myId }

    var isHost: Bool { view?.room.hostId == myId }
    var me: MemberView? { view?.members.first { $0.id == myId } }
    var title: String { "Trivia Clash" }
    /// True when this device runs the authoritative engine.
    var isAuthority: Bool { false }

    /// Accept a new authoritative view received at local time `receivedAt`.
    func apply(_ newView: PlayerView, receivedAt: Int64) {
        if let current = view, current.room.id == newView.room.id, newView.version < current.version { return }
        anchorLocalMs = receivedAt - 2 * oneWayLatencyMs
        if newView.round?.no != view?.round?.no || newView.room.matchNo != view?.room.matchNo {
            pendingChoice = nil
        }
        if let mine = newView.round?.myChoice { pendingChoice = mine }
        view = newView
    }

    /// Converts an authority timestamp into this device's monotonic clock.
    func localTime(ofAuthority t: Int64) -> Int64 {
        guard let view else { return t }
        return anchorLocalMs + (t - view.serverNow)
    }

    /// Milliseconds left until an authority deadline, as seen on this device.
    func remainingMs(until deadline: Int64?, now: Int64 = Monotonic.nowMs()) -> Int64 {
        guard let deadline else { return 0 }
        return max(0, localTime(ofAuthority: deadline) - now)
    }

    // MARK: Actions (overridden)

    func submit(choice: Int) {}
    func setReady(_ ready: Bool) {}
    func setTeam(target: String, team: Int) {}
    func shuffleTeams() {}
    func updateSettings(_ settings: MatchSettings, mode: GameMode?) {}
    func start() {}
    func skipReveal() {}
    func rematch() {}
    func kick(_ playerId: String) {}
    func leave() {}
    /// Called when the app returns to the foreground.
    func resume() {}

    static func message(for error: EngineError) -> String {
        switch error {
        case .notHost: return "Only the host can do that."
        case .notInLobby: return "That can only be changed in the lobby."
        case .roomFull: return "This room is full (12 players)."
        case .matchInProgress: return "A match is already in progress in this room."
        case .needMorePlayers: return "You need at least 2 players to start."
        case .playersNotReady: return "Waiting for everyone to tap Ready."
        case .teamEmpty: return "Every team needs at least one player."
        case .teamFull: return "That team is full. Try another or ask the host to balance."
        case .invalidTeam: return "That team doesn't exist."
        case .notTeamMode: return "Teams are only used in Team Battle."
        case .notMember: return "You're no longer in this room."
        case .notEnoughQuestions: return "Not enough questions for those settings. Add categories or change difficulty."
        case .invalidChoice: return "That answer isn't valid."
        case .notAllowed: return "That action isn't available right now."
        }
    }
}

/// A session whose authoritative engine runs on this device.
class EngineSession: GameSession {
    let engine: MatchEngine
    private var timer: Timer?
    private var publishedVersion = -1

    init(engine: MatchEngine, myId: String) {
        self.engine = engine
        super.init(myId: myId)
    }

    override var isAuthority: Bool { true }

    func startTicking() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pump() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        pump()
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    /// Advance due phases and publish if anything changed.
    func pump() {
        let now = Monotonic.nowMs()
        engine.tick(now: now)
        if engine.version != publishedVersion {
            publishedVersion = engine.version
            apply(engine.view(for: myId, now: now), receivedAt: now)
            didChange(now: now)
        }
    }

    /// Hook for subclasses (e.g. broadcast to nearby players).
    func didChange(now: Int64) {}

    func perform(_ action: (Int64) throws -> Void) {
        do {
            try action(Monotonic.nowMs())
        } catch let error as EngineError {
            notice = GameSession.message(for: error)
        } catch {
            notice = "Something went wrong."
        }
        pump()
    }

    override func submit(choice: Int) {
        guard let round = view?.round, pendingChoice == nil else { return }
        pendingChoice = choice
        perform { now in
            let outcome = try engine.submit(playerId: myId, round: round.no, choice: choice, now: now)
            if outcome.status == .tooLate { pendingChoice = nil; notice = "Time's up — that answer arrived too late." }
        }
    }

    override func setReady(_ ready: Bool) { perform { _ in try engine.setReady(myId, ready) } }
    override func setTeam(target: String, team: Int) { perform { _ in try engine.setTeam(by: myId, target: target, team: team) } }
    override func shuffleTeams() { perform { _ in try engine.shuffleTeams(by: myId) } }
    override func updateSettings(_ settings: MatchSettings, mode: GameMode?) {
        perform { _ in try engine.updateSettings(by: myId, settings: settings, mode: mode) }
    }
    override func start() { perform { now in try engine.start(by: myId, now: now) } }
    override func skipReveal() { perform { now in try engine.skipReveal(by: myId, now: now) } }
    override func rematch() { perform { _ in try engine.rematch(by: myId) } }
    override func kick(_ playerId: String) { perform { _ in try engine.kick(by: myId, target: playerId) } }
    override func leave() {
        perform { now in engine.leave(myId, now: now) }
        stopTicking()
    }
    override func resume() { pump() }
}

/// Offline single-player match. Uses exactly the same engine, timer and scoring
/// as multiplayer, with the device acting as its own authority.
final class SoloSession: EngineSession {
    init(profile: Profile, settings: MatchSettings, bank: QuestionBank, seen: Set<String>) {
        let engine = MatchEngine(mode: .solo, settings: settings) { settings, alsoSeen, count in
            bank.pick(settings: settings, seen: alsoSeen, count: count)
        }
        super.init(engine: engine, myId: profile.id)
        let now = Monotonic.nowMs()
        do {
            try engine.join(id: profile.id, name: profile.name, avatar: profile.avatar, seen: seen, now: now)
            try engine.start(by: profile.id, now: now)
        } catch let error as EngineError {
            notice = GameSession.message(for: error)
        } catch {
            notice = "Couldn't start the game."
        }
        startTicking()
    }

    override var title: String { "Solo" }

    var servedQuestionIds: [String] { engine.rounds.filter { $0.opensAt != nil }.map(\.question.id) }

    /// Starts a fresh solo game with the same settings. The engine remembers the
    /// questions just played, so the new set avoids them.
    func playAgain() {
        perform { now in
            try engine.rematch(by: myId)
            try engine.start(by: myId, now: now)
        }
    }
}
