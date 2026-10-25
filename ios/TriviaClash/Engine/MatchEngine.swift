import Foundation

enum EngineError: String, Error, Equatable {
    case notHost = "not_host"
    case notInLobby = "not_in_lobby"
    case roomFull = "room_full"
    case matchInProgress = "match_in_progress"
    case needMorePlayers = "need_more_players"
    case playersNotReady = "players_not_ready"
    case teamEmpty = "team_empty"
    case teamFull = "team_full"
    case invalidTeam = "invalid_team"
    case notTeamMode = "not_team_mode"
    case notMember = "not_member"
    case notEnoughQuestions = "not_enough_questions"
    case invalidChoice = "invalid_choice"
    case notAllowed = "not_allowed"
}

struct EngineTiming {
    var answerWindowMs: Int64 = 10_000
    var countdownMs: Int64 = 3_500
    var revealMs: Int64 = 7_000
    var soloRevealMs: Int64 = 90_000
    /// If nobody advanced the match for longer than this after a phase ended,
    /// the next question starts "now" so that it still gets its full window.
    var lateStartGraceMs: Int64 = 1_500
    /// How far ahead of its reveal time a question is sent out, so every phone
    /// has it before the shared reveal moment (0 for solo).
    var deliveryLeadMs: Int64 = 0
    /// Most network delay the authority will credit back to a remote player. Also
    /// how long a round stays open after its nominal deadline so their answers can
    /// still arrive (0 for solo).
    var maxCompensationMs: Int64 = 0
    /// A remote answer may arrive this much "before" the reveal because of clock-sync error.
    var earlyToleranceMs: Int64 = 250

    /// Settings for nearby multiplayer, where guests are a network hop away.
    static let nearby = EngineTiming(countdownMs: 2_500, deliveryLeadMs: 1_200, maxCompensationMs: 400)
}

/// The authoritative state machine for one room. It is the single source of
/// truth for deadlines, answers and scores. All time values are milliseconds on
/// the authority's monotonic clock and are passed in explicitly.
///
/// In solo play the engine runs on the player's device; in nearby play it runs
/// on the host's device and every other phone only ever sees `view(for:now:)`.
final class MatchEngine {
    struct Player {
        let id: String
        var name: String
        var avatar: Int
        var team: Int?
        var ready: Bool
        let joinSeq: Int
        var connected = true
        var left = false
        var score = 0
        var correct = 0
        var answered = 0
        var streak = 0
        var bestStreak = 0
        var correctMs: Int64 = 0
        var fastestMs: Int?
        var lastPoints = 0
        var lastCorrect: Bool?
    }

    struct Answer {
        let playerId: String
        let choice: Int
        let shownChoice: Int
        let receivedAt: Int64
        let responseMs: Int
        let correct: Bool
        let score: Scoring.Breakdown
    }

    struct Round {
        let no: Int
        let question: Question
        let seed: UInt64
        var multiplier: Int
        var opensAt: Int64?
        var closesAt: Int64?
        var closedAt: Int64?
        var answers: [String: Answer] = [:]
    }

    let roomId: String
    let code: String
    let maxPlayers = 12
    let timing: EngineTiming
    private(set) var mode: GameMode
    private(set) var settings: MatchSettings
    private(set) var phase: Phase = .lobby
    private(set) var phaseEndsAt: Int64?
    private(set) var hostId: String?
    private(set) var players: [Player] = []
    private(set) var rounds: [Round] = []
    private(set) var currentRound = 0
    private(set) var matchNo = 0
    /// Incremented on every observable change; views carry it so clients can drop stale updates.
    private(set) var version = 1

    private var joinCounter = 0
    private var seenByPlayer: [String: Set<String>] = [:]
    private let pickQuestions: (MatchSettings, Set<String>, Int) -> [Question]
    private var rng: SplitMix64

    init(mode: GameMode, settings: MatchSettings, code: String = RoomCode.generate(), timing: EngineTiming = EngineTiming(),
         seed: UInt64 = UInt64.random(in: .min ... .max),
         pickQuestions: @escaping (MatchSettings, Set<String>, Int) -> [Question]) {
        self.roomId = UUID().uuidString
        self.code = code
        self.mode = mode
        self.settings = settings.sanitized(for: mode)
        self.timing = timing
        self.rng = SplitMix64(seed: seed)
        self.pickQuestions = pickQuestions
    }

    // MARK: Membership

    var activePlayers: [Player] { players.filter { !$0.left } }

    func player(_ id: String) -> Player? { players.first { $0.id == id } }

    private func index(of id: String) -> Int? { players.firstIndex { $0.id == id } }

    /// Adds a player, or restores an existing seat (reconnect). Reconnecting never
    /// changes deadlines or existing answers.
    @discardableResult
    func join(id: String, name: String, avatar: Int, seen: Set<String> = [], now: Int64) throws -> Player {
        if let i = index(of: id) {
            players[i].left = false
            players[i].connected = true
            if !seen.isEmpty { seenByPlayer[id, default: []].formUnion(seen) }
            if hostId == nil { hostId = id }
            bump()
            return players[i]
        }
        guard phase == .lobby else { throw EngineError.matchInProgress }
        guard activePlayers.count < (mode == .solo ? 1 : maxPlayers) else { throw EngineError.roomFull }
        joinCounter += 1
        var p = Player(id: id, name: uniqueName(name, excluding: id), avatar: avatar, team: nil,
                       ready: players.isEmpty, joinSeq: joinCounter)
        if hostId == nil { hostId = id; p.ready = true }
        players.append(p)
        seenByPlayer[id] = seen
        if mode == .teams { fillTeams() }
        bump()
        return players[players.count - 1]
    }

    func setConnected(_ id: String, _ connected: Bool) {
        guard let i = index(of: id), players[i].connected != connected else { return }
        players[i].connected = connected
        bump()
    }

    func leave(_ id: String, now: Int64) {
        guard let i = index(of: id) else { return }
        if mode == .solo {
            phase = .closed
            phaseEndsAt = nil
        } else if phase == .lobby || phase == .finished {
            players.remove(at: i)
        } else {
            players[i].left = true
            players[i].ready = false
            if phase == .question, allActiveAnswered() { closeRound(at: now) }
        }
        if hostId == id, mode != .solo { reassignHost() }
        if mode != .solo, activePlayers.isEmpty {
            phase = .closed
            phaseEndsAt = nil
        }
        bump()
    }

    func kick(by requester: String, target: String) throws {
        try requireHost(requester)
        guard phase == .lobby else { throw EngineError.notInLobby }
        guard target != requester else { throw EngineError.notAllowed }
        players.removeAll { $0.id == target }
        bump()
    }

    private func reassignHost() {
        let candidates = activePlayers.sorted { ($0.connected ? 0 : 1, $0.joinSeq) < ($1.connected ? 0 : 1, $1.joinSeq) }
        hostId = candidates.first?.id
        if hostId == nil {
            phase = .closed
            phaseEndsAt = nil
        }
    }

    private func uniqueName(_ name: String, excluding id: String) -> String {
        let taken = Set(activePlayers.filter { $0.id != id }.map { $0.name.lowercased() })
        if !taken.contains(name.lowercased()) { return name }
        var n = 2
        while taken.contains("\(name.prefix(13)) \(n)".lowercased()) { n += 1 }
        return "\(name.prefix(13)) \(n)"
    }

    // MARK: Lobby controls

    private func requireHost(_ id: String) throws {
        guard id == hostId else { throw EngineError.notHost }
    }

    func setReady(_ id: String, _ ready: Bool) throws {
        guard phase == .lobby else { throw EngineError.notInLobby }
        guard let i = index(of: id), !players[i].left else { throw EngineError.notMember }
        players[i].ready = ready
        bump()
    }

    func updateSettings(by requester: String, settings newSettings: MatchSettings, mode newMode: GameMode? = nil) throws {
        try requireHost(requester)
        guard phase == .lobby else { throw EngineError.notInLobby }
        if let newMode, newMode != .solo, mode != .solo { mode = newMode }
        settings = newSettings.sanitized(for: mode)
        if mode == .teams {
            for i in players.indices where (players[i].team ?? 0) >= settings.teamCount { players[i].team = nil }
            fillTeams()
        } else {
            for i in players.indices { players[i].team = nil }
        }
        bump()
    }

    /// Players may move themselves; the host may move anyone. Non-hosts cannot
    /// stack a team beyond ceil(players / teams).
    func setTeam(by requester: String, target: String, team: Int) throws {
        guard mode == .teams else { throw EngineError.notTeamMode }
        guard phase == .lobby else { throw EngineError.notInLobby }
        guard (0..<settings.teamCount).contains(team) else { throw EngineError.invalidTeam }
        if target != requester { try requireHost(requester) }
        guard let i = index(of: target), !players[i].left else { throw EngineError.notMember }
        if requester != hostId {
            let cap = Int((Double(activePlayers.count) / Double(settings.teamCount)).rounded(.up))
            let size = activePlayers.filter { $0.team == team && $0.id != target }.count
            if size >= cap { throw EngineError.teamFull }
        }
        players[i].team = team
        bump()
    }

    func shuffleTeams(by requester: String) throws {
        try requireHost(requester)
        guard mode == .teams, phase == .lobby else { throw EngineError.notInLobby }
        var ids = activePlayers.map(\.id)
        ids.shuffle(using: &rng)
        for (n, id) in ids.enumerated() {
            if let i = index(of: id) { players[i].team = n % settings.teamCount }
        }
        bump()
    }

    private func fillTeams() {
        for i in players.indices where !players[i].left && players[i].team == nil {
            var counts = Array(repeating: 0, count: settings.teamCount)
            for p in activePlayers { if let t = p.team, t < counts.count { counts[t] += 1 } }
            let smallest = counts.enumerated().min { ($0.element, $0.offset) < ($1.element, $1.offset) }?.offset ?? 0
            players[i].team = smallest
        }
    }

    // MARK: Match lifecycle

    /// Reasons the host cannot start yet, or nil when the match can start.
    var startBlocker: EngineError? {
        guard phase == .lobby else { return .notInLobby }
        if mode == .solo { return nil }
        let active = activePlayers
        if active.count < 2 { return .needMorePlayers }
        if active.contains(where: { $0.id != hostId && !$0.ready && $0.connected }) { return .playersNotReady }
        return nil
    }

    func start(by requester: String, now: Int64) throws {
        try requireHost(requester)
        guard phase == .lobby else { throw EngineError.notInLobby }
        if mode != .solo {
            // Players who dropped off before the start are removed rather than blocking it.
            players.removeAll { $0.id != hostId && !$0.connected }
            if let error = startBlocker { throw error }
        }
        if mode == .teams {
            fillTeams()
            let used = Set(activePlayers.compactMap(\.team))
            if used.count < settings.teamCount { throw EngineError.teamEmpty }
        }

        let seen = activePlayers.reduce(into: Set<String>()) { $0.formUnion(seenByPlayer[$1.id] ?? []) }
        let questions = pickQuestions(settings, seen, settings.questionCount)
        guard questions.count >= 3 else { throw EngineError.notEnoughQuestions }

        players.removeAll { $0.left }
        for i in players.indices {
            players[i].score = 0; players[i].correct = 0; players[i].answered = 0
            players[i].streak = 0; players[i].bestStreak = 0; players[i].correctMs = 0
            players[i].fastestMs = nil; players[i].lastPoints = 0; players[i].lastCorrect = nil
        }
        matchNo += 1
        rounds = questions.enumerated().map { n, q in
            Round(no: n + 1, question: q, seed: rng.next(),
                  multiplier: settings.finalDouble && n == questions.count - 1 ? 2 : 1)
        }
        for p in activePlayers { seenByPlayer[p.id, default: []].formUnion(questions.map(\.id)) }
        currentRound = 0
        phase = .countdown
        phaseEndsAt = now + timing.countdownMs
        bump()
    }

    /// Advances every phase whose deadline has passed. Returns true if anything changed.
    @discardableResult
    func tick(now: Int64) -> Bool {
        var changed = false
        var guardCount = 0
        while let ends = phaseEndsAt, ends <= now, guardCount < 6 {
            guardCount += 1
            changed = true
            let startAt = now - ends < timing.lateStartGraceMs ? ends : now
            switch phase {
            case .countdown:
                openRound(1, at: startAt)
            case .question:
                closeRound(at: ends)
            case .reveal:
                if currentRound >= rounds.count { finish() } else { openRound(currentRound + 1, at: startAt) }
            default:
                phaseEndsAt = nil
            }
        }
        if changed { bump() }
        return changed
    }

    /// The question is published at `time` but revealed at `time + deliveryLeadMs`,
    /// so it reaches every phone before the shared reveal moment. The round stays
    /// open `maxCompensationMs` past the nominal deadline for in-flight answers.
    private func openRound(_ no: Int, at time: Int64) {
        let i = no - 1
        let reveal = time + timing.deliveryLeadMs
        rounds[i].opensAt = reveal
        rounds[i].closesAt = reveal + timing.answerWindowMs
        currentRound = no
        phase = .question
        phaseEndsAt = reveal + timing.answerWindowMs + timing.maxCompensationMs
    }

    private func allActiveAnswered() -> Bool {
        guard currentRound > 0 else { return false }
        let answers = rounds[currentRound - 1].answers
        let active = activePlayers
        return !active.isEmpty && active.allSatisfy { answers[$0.id] != nil }
    }

    /// Applies the hidden per-answer scores, breaks streaks of non-answerers and
    /// moves to the reveal. Scores are applied here (not at submission) so that
    /// nobody can infer correctness from a score change while a round is open.
    private func closeRound(at time: Int64) {
        let i = currentRound - 1
        guard i >= 0, rounds[i].closedAt == nil else { return }
        rounds[i].closedAt = time
        let answers = rounds[i].answers
        for p in players.indices {
            if let a = answers[players[p].id] {
                players[p].score += a.score.total
                players[p].answered += 1
                players[p].lastPoints = a.score.total
                players[p].lastCorrect = a.correct
                if a.correct {
                    players[p].correct += 1
                    players[p].streak += 1
                    players[p].bestStreak = max(players[p].bestStreak, players[p].streak)
                    players[p].correctMs += Int64(a.responseMs)
                    players[p].fastestMs = min(players[p].fastestMs ?? a.responseMs, a.responseMs)
                } else {
                    players[p].streak = 0
                }
            } else {
                players[p].streak = 0
                players[p].lastPoints = 0
                players[p].lastCorrect = nil
            }
        }
        phase = .reveal
        phaseEndsAt = time + (mode == .solo ? timing.soloRevealMs : timing.revealMs)
    }

    private func finish() {
        phase = .finished
        phaseEndsAt = nil
    }

    /// Submits the answer shown at display position `choice` (0–3). The first
    /// accepted answer is final.
    ///
    /// Answer time is measured from the shared reveal moment. For the authority's
    /// own player it is simply `now − opensAt`. A remote player reports the
    /// reaction time measured on their own phone (`reportedElapsedMs`), so network
    /// delay doesn't count against them. The report is trusted only within
    /// `compensationMs` (the measured round-trip to that player, capped at
    /// `maxCompensationMs`). Nobody can claim to be faster than the arrival time
    /// allows by more than that, and anything that works out at or past 10 s scores nothing.
    func submit(playerId: String, round roundNo: Int, choice: Int, now: Int64,
                reportedElapsedMs: Int64? = nil, compensationMs: Int64 = 0) throws -> SubmitOutcome {
        guard (0...3).contains(choice) else { throw EngineError.invalidChoice }
        guard let pi = index(of: playerId), !players[pi].left else { throw EngineError.notMember }
        guard roundNo >= 1, roundNo <= rounds.count, rounds[roundNo - 1].opensAt != nil else {
            return SubmitOutcome(status: .notActive, choice: nil)
        }
        let ri = roundNo - 1
        if let existing = rounds[ri].answers[playerId] {
            return SubmitOutcome(status: .alreadyAnswered, choice: existing.shownChoice)
        }
        let isRemote = reportedElapsedMs != nil
        let compensation = isRemote ? min(max(compensationMs, 0), timing.maxCompensationMs) : 0
        guard phase == .question, currentRound == roundNo, rounds[ri].closedAt == nil,
              let opens = rounds[ri].opensAt, let closes = rounds[ri].closesAt,
              now < closes + compensation else {
            tick(now: now)
            return SubmitOutcome(status: .tooLate, choice: nil)
        }
        guard now >= opens - (isRemote ? timing.earlyToleranceMs : 0) else {
            return SubmitOutcome(status: .notActive, choice: nil)
        }
        let arrivalElapsed = max(0, now - opens)
        var elapsed = arrivalElapsed
        if let reported = reportedElapsedMs {
            elapsed = min(arrivalElapsed, max(reported, arrivalElapsed - compensation, 0))
        }
        guard elapsed < timing.answerWindowMs else {
            tick(now: now)
            return SubmitOutcome(status: .tooLate, choice: nil)
        }
        let perm = AnswerOrder.permutation(seed: rounds[ri].seed, playerId: playerId)
        let original = perm[choice]
        let correct = original == rounds[ri].question.answer
        let remaining = timing.answerWindowMs - elapsed
        let breakdown = Scoring.score(correct: correct, remainingMs: remaining,
                                      streakBefore: players[pi].streak, multiplier: rounds[ri].multiplier)
        rounds[ri].answers[playerId] = Answer(playerId: playerId, choice: original, shownChoice: choice, receivedAt: now,
                                              responseMs: Int(timing.answerWindowMs - remaining), correct: correct,
                                              score: breakdown)
        if allActiveAnswered() { closeRound(at: now) }
        bump()
        return SubmitOutcome(status: .accepted, choice: choice)
    }

    /// Solo only: skip the rest of the reveal and continue immediately.
    func skipReveal(by requester: String, now: Int64) throws {
        guard mode == .solo, requester == hostId else { throw EngineError.notAllowed }
        guard phase == .reveal else { return }
        phaseEndsAt = now
        tick(now: now)
    }

    func rematch(by requester: String) throws {
        try requireHost(requester)
        guard phase == .finished else { throw EngineError.notAllowed }
        players.removeAll { $0.left }
        for i in players.indices {
            players[i].ready = players[i].id == hostId
            players[i].score = 0; players[i].correct = 0; players[i].answered = 0
            players[i].streak = 0; players[i].bestStreak = 0; players[i].correctMs = 0
            players[i].fastestMs = nil; players[i].lastPoints = 0; players[i].lastCorrect = nil
        }
        rounds = []
        currentRound = 0
        phase = .lobby
        phaseEndsAt = nil
        bump()
    }

    func close() {
        phase = .closed
        phaseEndsAt = nil
        bump()
    }

    private func bump() { version += 1 }

    // MARK: Standings

    /// Players ordered by score, then correct answers, then total time on correct
    /// answers (lower is better), then join order. Fully tied players share a rank.
    func standings(includeLeft: Bool = true) -> [(player: Player, rank: Int)] {
        let list = players.filter { includeLeft || !$0.left }
        let sorted = list.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.correct != $1.correct { return $0.correct > $1.correct }
            if $0.correctMs != $1.correctMs { return $0.correctMs < $1.correctMs }
            return $0.joinSeq < $1.joinSeq
        }
        var result: [(Player, Int)] = []
        for (n, p) in sorted.enumerated() {
            if let prev = result.last, prev.0.score == p.score, prev.0.correct == p.correct, prev.0.correctMs == p.correctMs {
                result.append((p, prev.1))
            } else {
                result.append((p, n + 1))
            }
        }
        return result.map { (player: $0.0, rank: $0.1) }
    }

    /// Team score = average points per member (rounded), so uneven teams stay fair.
    /// Ties are broken by total correct answers; equal teams share a rank.
    func teamStandings(includeLeft: Bool) -> [TeamView] {
        let teams: [TeamView] = (0..<settings.teamCount).map { t in
            let members = players.filter { $0.team == t && (includeLeft || !$0.left) }
            let total = members.reduce(0) { $0 + $1.score }
            let correct = members.reduce(0) { $0 + $1.correct }
            let avg = members.isEmpty ? 0 : Int((Double(total) / Double(members.count)).rounded())
            return TeamView(index: t, size: members.count, score: avg, total: total, correct: correct, rank: 0)
        }
        let sorted = teams.sorted { ($0.score, $0.correct, -$0.index) > ($1.score, $1.correct, -$1.index) }
        var ranked: [TeamView] = []
        for (n, var team) in sorted.enumerated() {
            if let prev = ranked.last, prev.score == team.score, prev.correct == team.correct {
                team.rank = prev.rank
            } else {
                team.rank = n + 1
            }
            ranked.append(team)
        }
        return ranked
    }

    // MARK: Views

    func view(for playerId: String, now: Int64) -> PlayerView {
        let round: Round? = (currentRound > 0 && currentRound <= rounds.count) ? rounds[currentRound - 1] : nil
        let lobbyLike = phase == .lobby
        let members: [MemberView] = standings(includeLeft: !lobbyLike).map { entry in
            let p = entry.player
            return MemberView(id: p.id, name: p.name, avatar: p.avatar, team: p.team, ready: p.ready,
                              host: p.id == hostId, connected: p.connected, left: p.left,
                              score: p.score, correct: p.correct, answered: p.answered, streak: p.streak,
                              bestStreak: p.bestStreak, fastestMs: p.fastestMs,
                              avgMs: p.correct > 0 ? Int(p.correctMs / Int64(p.correct)) : nil,
                              lastPoints: p.lastPoints, lastCorrect: p.lastCorrect, rank: entry.rank,
                              lockedIn: phase == .question && round?.answers[p.id] != nil)
        }

        var roundView: RoundView?
        var revealView: RevealView?
        if let round, let opens = round.opensAt, let closes = round.closesAt,
           phase == .question || phase == .reveal || phase == .finished {
            let perm = AnswerOrder.permutation(seed: round.seed, playerId: playerId)
            let mine = round.answers[playerId]
            roundView = RoundView(no: round.no, total: rounds.count, category: round.question.category,
                                  difficulty: round.question.difficulty, prompt: round.question.prompt,
                                  options: perm.map { round.question.options[$0] }, opensAt: opens, closesAt: closes,
                                  multiplier: round.multiplier, answeredCount: round.answers.count,
                                  myChoice: mine?.shownChoice, closed: round.closedAt != nil)
            if round.closedAt != nil {
                let distribution = perm.map { original in round.answers.values.filter { $0.choice == original }.count }
                revealView = RevealView(
                    correctChoice: perm.firstIndex(of: round.question.answer) ?? 0,
                    explanation: round.question.explanation, source: round.question.source,
                    my: mine.map { AnswerResult(correct: $0.correct, points: $0.score.total, base: $0.score.base,
                                                speed: $0.score.speed, streakBonus: $0.score.streakBonus,
                                                responseMs: $0.responseMs) },
                    distribution: distribution)
            }
        }

        let info = RoomInfo(id: roomId, code: code, mode: mode, status: phase, hostId: hostId,
                            questionCount: settings.questionCount, totalRounds: rounds.count,
                            categories: settings.categories, difficulty: settings.difficulty,
                            teamCount: settings.teamCount, finalDouble: settings.finalDouble, matchNo: matchNo,
                            currentRound: currentRound, phaseEndsAt: phaseEndsAt, maxPlayers: maxPlayers)
        return PlayerView(serverNow: now, version: version, me: playerId, room: info, members: members,
                          teams: mode == .teams ? teamStandings(includeLeft: !lobbyLike) : nil,
                          round: roundView, reveal: revealView)
    }
}
