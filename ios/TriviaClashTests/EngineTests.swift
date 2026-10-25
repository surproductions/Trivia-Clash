import XCTest
@testable import TriviaClash

final class ScoringTests: XCTestCase {
    func testCorrectAnswerScoresBasePlusSpeed() {
        let s = Scoring.score(correct: true, remainingMs: 10_000, streakBefore: 0, multiplier: 1)
        XCTAssertEqual(s, Scoring.Breakdown(base: 1000, speed: 250, streakBonus: 0, total: 1250))
    }

    func testSpeedBonusIsFlooredFromRemainingTime() {
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 5_000, streakBefore: 0, multiplier: 1).speed, 125)
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 39, streakBefore: 0, multiplier: 1).speed, 0)
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 41, streakBefore: 0, multiplier: 1).speed, 1)
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 9_999, streakBefore: 0, multiplier: 1).speed, 249)
    }

    func testOutOfRangeTimesAreClamped() {
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: -500, streakBefore: 0, multiplier: 1).total, 1000)
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 99_000, streakBefore: 0, multiplier: 1).speed, 250)
    }

    func testWrongAnswerScoresNothing() {
        XCTAssertEqual(Scoring.score(correct: false, remainingMs: 9_000, streakBefore: 3, multiplier: 2).total, 0)
    }

    func testStreakBonusIsCapped() {
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 0, streakBefore: 1, multiplier: 1).streakBonus, 50)
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 0, streakBefore: 4, multiplier: 1).streakBonus, 200)
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 0, streakBefore: 40, multiplier: 1).streakBonus, 200)
    }

    func testDoublePointsMultiplierAndClamp() {
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 10_000, streakBefore: 0, multiplier: 2).total, 2500)
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 10_000, streakBefore: 0, multiplier: 9).total, 2500)
        XCTAssertEqual(Scoring.score(correct: true, remainingMs: 10_000, streakBefore: 0, multiplier: 0).total, 1250)
    }
}

final class AnswerOrderTests: XCTestCase {
    func testPermutationIsAValidShuffle() {
        for seed in 0..<200 as Range<UInt64> {
            XCTAssertEqual(AnswerOrder.permutation(seed: seed, playerId: "p").sorted(), [0, 1, 2, 3])
        }
    }

    func testPermutationIsDeterministic() {
        XCTAssertEqual(AnswerOrder.permutation(seed: 7, playerId: "alice"), AnswerOrder.permutation(seed: 7, playerId: "alice"))
    }

    func testPlayersGetDifferentOrdersAcrossRounds() {
        var distinct = Set<[Int]>()
        for seed in 0..<50 as Range<UInt64> {
            distinct.insert(AnswerOrder.permutation(seed: seed, playerId: "alice"))
        }
        XCTAssertGreaterThan(distinct.count, 10, "answer positions should vary between rounds")
        let differs = (0..<50 as Range<UInt64>).contains {
            AnswerOrder.permutation(seed: $0, playerId: "alice") != AnswerOrder.permutation(seed: $0, playerId: "bob")
        }
        XCTAssertTrue(differs, "players in the same round should usually see different orders")
    }
}

final class RoomCodeTests: XCTestCase {
    func testGeneratedCodesUseUnambiguousAlphabet() {
        var rng = SplitMix64(seed: 1)
        for _ in 0..<500 {
            let code = RoomCode.generate(using: &rng)
            XCTAssertTrue(RoomCode.isValid(code))
            XCTAssertFalse(code.contains { "O0I1L".contains($0) })
        }
    }

    func testNormalizeUppercasesAndStripsNoise() {
        XCTAssertEqual(RoomCode.normalize("ab-cd e"), "ABCDE")
        XCTAssertEqual(RoomCode.normalize("abcdefgh"), "ABCDE")
        XCTAssertEqual(RoomCode.normalize("o0i1l"), "")
        XCTAssertFalse(RoomCode.isValid("ABCD"))
    }
}

final class MatchEngineTests: XCTestCase {
    func testFullMatchFlowAndScoring() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        XCTAssertEqual(e.phase, .question)
        XCTAssertEqual(e.currentRound, 1)

        let r1 = try e.submit(playerId: "host", round: 1, choice: e.correctChoice(for: "host"), now: open + 2_000)
        XCTAssertEqual(r1.status, .accepted)
        // Scores are hidden until the round closes.
        XCTAssertEqual(e.player("host")?.score, 0)
        _ = try e.submit(playerId: "guest", round: 1, choice: e.wrongChoice(for: "guest"), now: open + 3_000)
        // Everyone answered → round closes early.
        XCTAssertEqual(e.phase, .reveal)
        XCTAssertEqual(e.player("host")?.score, 1000 + 200)
        XCTAssertEqual(e.player("guest")?.score, 0)
        XCTAssertEqual(e.player("host")?.streak, 1)
    }

    func testAnswerAtOrAfterDeadlineIsRejected() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        let deadline = open + 10_000
        let late = try e.submit(playerId: "guest", round: 1, choice: 0, now: deadline)
        XCTAssertEqual(late.status, .tooLate)
        XCTAssertEqual(e.phase, .reveal, "the late submission also closes the overdue round")
        XCTAssertEqual(e.player("guest")?.score, 0)
    }

    func testAnswerOneMillisecondBeforeDeadlineIsAccepted() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        let r = try e.submit(playerId: "guest", round: 1, choice: e.correctChoice(for: "guest"), now: open + 9_999)
        XCTAssertEqual(r.status, .accepted)
        e.tick(now: open + 10_000)
        XCTAssertEqual(e.player("guest")?.score, 1000)
    }

    func testFirstAnswerIsFinalAndDuplicatesDoNotScoreTwice() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest", "third"])
        let wrong = e.wrongChoice(for: "guest")
        XCTAssertEqual(try e.submit(playerId: "guest", round: 1, choice: wrong, now: open + 1_000).status, .accepted)
        let retry = try e.submit(playerId: "guest", round: 1, choice: e.correctChoice(for: "guest"), now: open + 1_100)
        XCTAssertEqual(retry.status, .alreadyAnswered)
        XCTAssertEqual(retry.choice, wrong)
        e.tick(now: open + 10_000)
        XCTAssertEqual(e.player("guest")?.score, 0)
        XCTAssertEqual(e.player("guest")?.answered, 1)
    }

    func testCannotAnswerAFutureOrPastRound() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        XCTAssertEqual(try e.submit(playerId: "guest", round: 2, choice: 0, now: open + 100).status, .notActive)
        e.tick(now: open + 10_000)
        e.tick(now: open + 10_000 + e.timing.revealMs)
        XCTAssertEqual(e.currentRound, 2)
        XCTAssertEqual(try e.submit(playerId: "guest", round: 1, choice: 0, now: open + 17_100).status, .tooLate)
    }

    func testInvalidChoiceAndNonMemberAreRejected() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        XCTAssertThrowsError(try e.submit(playerId: "guest", round: 1, choice: 4, now: open)) {
            XCTAssertEqual($0 as? EngineError, .invalidChoice)
        }
        XCTAssertThrowsError(try e.submit(playerId: "stranger", round: 1, choice: 0, now: open)) {
            XCTAssertEqual($0 as? EngineError, .notMember)
        }
    }

    func testNoAnswerBreaksStreak() throws {
        let e = Fixtures.engine()
        var open = try e.startStandard(["host", "guest"])
        _ = try e.submit(playerId: "guest", round: 1, choice: e.correctChoice(for: "guest"), now: open + 500)
        e.tick(now: open + 10_000)
        XCTAssertEqual(e.player("guest")?.streak, 1)
        open = open + 10_000 + e.timing.revealMs
        e.tick(now: open)
        e.tick(now: open + 10_000) // guest silent in round 2
        XCTAssertEqual(e.player("guest")?.streak, 0)
        XCTAssertEqual(e.player("guest")?.bestStreak, 1)
    }

    func testStreakBonusAppliesOnConsecutiveCorrectAnswers() throws {
        let e = Fixtures.engine()
        var open = try e.startStandard(["host", "guest"])
        for round in 1...3 {
            _ = try e.submit(playerId: "host", round: round, choice: e.correctChoice(for: "host"), now: open + 10_000 - 1)
            e.tick(now: open + 10_000)
            open += 10_000 + e.timing.revealMs
            e.tick(now: open)
        }
        // Each answer: 1000 + floor(250*1/10000)=0 speed; streak bonuses 0, 50, 100.
        XCTAssertEqual(e.player("host")?.score, 3000 + 150)
    }

    func testMatchFinishesAfterLastRoundAndFinalDouble() throws {
        let e = Fixtures.engine(settings: MatchSettings(questionCount: 5, finalDouble: true))
        var open = try e.startStandard(["host", "guest"])
        XCTAssertEqual(e.rounds.last?.multiplier, 2)
        XCTAssertEqual(e.rounds.dropLast().map(\.multiplier), [1, 1, 1, 1])
        for round in 1...5 {
            XCTAssertEqual(e.currentRound, round)
            if round == 5 {
                _ = try e.submit(playerId: "host", round: 5, choice: e.correctChoice(for: "host"), now: open)
            }
            e.tick(now: open + 10_000)
            open += 10_000 + e.timing.revealMs
            e.tick(now: open)
        }
        XCTAssertEqual(e.phase, .finished)
        XCTAssertEqual(e.player("host")?.score, 2500)
    }

    func testLateObserverStillGetsFullWindow() throws {
        let e = Fixtures.engine()
        try e.join(id: "host", name: "host", avatar: 0, now: 0)
        try e.join(id: "guest", name: "guest", avatar: 0, now: 0)
        try e.setReady("guest", true)
        try e.start(by: "host", now: 0)
        // Nobody ticks for a long time after the countdown ended.
        let wake = e.timing.countdownMs + 60_000
        e.tick(now: wake)
        XCTAssertEqual(e.phase, .question)
        XCTAssertEqual(e.rounds[0].opensAt, wake)
        XCTAssertEqual(e.rounds[0].closesAt, wake + 10_000)
    }

    func testReconnectDoesNotExtendTimerOrAllowSecondAnswer() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        _ = try e.submit(playerId: "guest", round: 1, choice: 1, now: open + 1_000)
        e.setConnected("guest", false)
        try e.join(id: "guest", name: "guest", avatar: 0, now: open + 5_000)
        XCTAssertEqual(e.rounds[0].closesAt, open + 10_000)
        XCTAssertEqual(try e.submit(playerId: "guest", round: 1, choice: 2, now: open + 5_100).status, .alreadyAnswered)
        let view = e.view(for: "guest", now: open + 5_100)
        XCTAssertEqual(view.round?.myChoice, 1)
        XCTAssertEqual(view.round?.closesAt, open + 10_000)
    }

    func testNewPlayersCannotJoinMidMatchButMembersCanRejoin() throws {
        let e = Fixtures.engine()
        try e.startStandard(["host", "guest"])
        XCTAssertThrowsError(try e.join(id: "late", name: "Late", avatar: 0, now: 5_000)) {
            XCTAssertEqual($0 as? EngineError, .matchInProgress)
        }
        e.leave("guest", now: 5_000)
        XCTAssertNoThrow(try e.join(id: "guest", name: "guest", avatar: 0, now: 6_000))
        XCTAssertEqual(e.player("guest")?.left, false)
    }

    func testViewNeverRevealsAnswerBeforeClose() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        let view = e.view(for: "guest", now: open + 100)
        XCTAssertNotNil(view.round)
        XCTAssertNil(view.reveal)
        XCTAssertEqual(view.round?.closed, false)
        // Other players' correctness/score cannot be inferred mid-round.
        _ = try e.submit(playerId: "host", round: 1, choice: e.correctChoice(for: "host"), now: open + 200)
        let after = e.view(for: "guest", now: open + 300)
        XCTAssertNil(after.reveal)
        XCTAssertEqual(after.members.first { $0.id == "host" }?.score, 0)
        XCTAssertEqual(after.members.first { $0.id == "host" }?.lockedIn, true)
    }

    func testRevealMapsCorrectAnswerToEachPlayersOwnOrder() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        let hostCorrect = e.correctChoice(for: "host")
        let guestCorrect = e.correctChoice(for: "guest")
        e.tick(now: open + 10_000)
        let hv = e.view(for: "host", now: open + 10_001)
        let gv = e.view(for: "guest", now: open + 10_001)
        XCTAssertEqual(hv.reveal?.correctChoice, hostCorrect)
        XCTAssertEqual(gv.reveal?.correctChoice, guestCorrect)
        let q = e.rounds[0].question
        XCTAssertEqual(hv.round?.options[hostCorrect], q.options[q.answer])
        XCTAssertEqual(gv.round?.options[guestCorrect], q.options[q.answer])
    }

    func testLeavingDuringQuestionClosesRoundIfOthersAnswered() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "a", "b"])
        _ = try e.submit(playerId: "host", round: 1, choice: 0, now: open + 100)
        _ = try e.submit(playerId: "a", round: 1, choice: 0, now: open + 200)
        e.leave("b", now: open + 300)
        XCTAssertEqual(e.phase, .reveal)
    }

    func testHostLeavingHandsOverHost() throws {
        let e = Fixtures.engine()
        for id in ["host", "a", "b"] { try e.join(id: id, name: id, avatar: 0, now: 0) }
        e.leave("host", now: 10)
        XCTAssertEqual(e.hostId, "a")
        e.leave("a", now: 20)
        e.leave("b", now: 30)
        XCTAssertEqual(e.phase, .closed)
    }

    func testOnlyHostCanStartOrChangeSettings() throws {
        let e = Fixtures.engine()
        try e.join(id: "host", name: "Host", avatar: 0, now: 0)
        try e.join(id: "guest", name: "Guest", avatar: 0, now: 0)
        XCTAssertThrowsError(try e.start(by: "guest", now: 0)) { XCTAssertEqual($0 as? EngineError, .notHost) }
        XCTAssertThrowsError(try e.updateSettings(by: "guest", settings: MatchSettings())) {
            XCTAssertEqual($0 as? EngineError, .notHost)
        }
        XCTAssertThrowsError(try e.start(by: "host", now: 0)) { XCTAssertEqual($0 as? EngineError, .playersNotReady) }
        try e.setReady("guest", true)
        XCTAssertNoThrow(try e.start(by: "host", now: 0))
    }

    func testNeedsTwoPlayersAndRoomCap() throws {
        let e = Fixtures.engine()
        try e.join(id: "host", name: "Host", avatar: 0, now: 0)
        XCTAssertThrowsError(try e.start(by: "host", now: 0)) { XCTAssertEqual($0 as? EngineError, .needMorePlayers) }
        for i in 1..<12 { try e.join(id: "p\(i)", name: "P\(i)", avatar: 0, now: 0) }
        XCTAssertThrowsError(try e.join(id: "p12", name: "P12", avatar: 0, now: 0)) { XCTAssertEqual($0 as? EngineError, .roomFull) }
    }

    func testDuplicateNamesAreDisambiguated() throws {
        let e = Fixtures.engine()
        try e.join(id: "1", name: "Sam", avatar: 0, now: 0)
        try e.join(id: "2", name: "sam", avatar: 0, now: 0)
        try e.join(id: "3", name: "Sam", avatar: 0, now: 0)
        XCTAssertEqual(e.players.map(\.name), ["Sam", "sam 2", "Sam 3"])
    }

    func testTiesShareRankAndOrderIsDeterministic() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "a", "b"])
        _ = try e.submit(playerId: "a", round: 1, choice: e.correctChoice(for: "a"), now: open + 1_000)
        _ = try e.submit(playerId: "b", round: 1, choice: e.correctChoice(for: "b"), now: open + 1_000)
        _ = try e.submit(playerId: "host", round: 1, choice: e.wrongChoice(for: "host"), now: open + 1_000)
        let standings = e.standings()
        XCTAssertEqual(standings.map(\.player.id), ["a", "b", "host"])
        XCTAssertEqual(standings.map(\.rank), [1, 1, 3])
    }

    func testFasterTotalTimeBreaksScoreTies() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "a", "b"])
        // 8,970 ms and 8,990 ms remaining both floor to a 224-point speed bonus, so the
        // scores tie and the faster answer (b) wins the tie-break.
        _ = try e.submit(playerId: "a", round: 1, choice: e.correctChoice(for: "a"), now: open + 1_030)
        _ = try e.submit(playerId: "b", round: 1, choice: e.correctChoice(for: "b"), now: open + 1_010)
        _ = try e.submit(playerId: "host", round: 1, choice: e.wrongChoice(for: "host"), now: open + 1_000)
        XCTAssertEqual(e.player("a")?.score, e.player("b")?.score)
        XCTAssertEqual(e.standings().map(\.player.id).prefix(2), ["b", "a"])
        XCTAssertEqual(e.standings().map(\.rank).prefix(2), [1, 2])
    }

    func testSoloRevealCanBeSkipped() throws {
        let e = Fixtures.engine(mode: .solo, settings: MatchSettings(questionCount: 10))
        try e.join(id: "me", name: "Me", avatar: 0, now: 0)
        try e.start(by: "me", now: 0)
        e.tick(now: e.timing.countdownMs)
        _ = try e.submit(playerId: "me", round: 1, choice: 0, now: 4_000)
        XCTAssertEqual(e.phase, .reveal, "a solo answer closes the round immediately")
        try e.skipReveal(by: "me", now: 4_500)
        XCTAssertEqual(e.phase, .question)
        XCTAssertEqual(e.currentRound, 2)
        XCTAssertEqual(e.rounds[1].opensAt, 4_500)
    }

    func testRematchResetsScoresAndAvoidsRepeatQuestions() throws {
        let e = Fixtures.engine()
        var open = try e.startStandard(["host", "guest"])
        let firstIds = Set(e.rounds.map(\.question.id))
        for _ in 1...5 {
            e.tick(now: open + 10_000)
            open += 10_000 + e.timing.revealMs
            e.tick(now: open)
        }
        XCTAssertEqual(e.phase, .finished)
        try e.rematch(by: "host")
        XCTAssertEqual(e.phase, .lobby)
        XCTAssertEqual(e.player("guest")?.ready, false)
        try e.setReady("guest", true)
        try e.start(by: "host", now: open)
        XCTAssertTrue(firstIds.isDisjoint(with: e.rounds.map(\.question.id)))
        XCTAssertEqual(e.players.map(\.score), [0, 0])
    }

    func testNotEnoughQuestionsIsReported() throws {
        let e = Fixtures.engine(questions: [Fixtures.question(1), Fixtures.question(2)])
        try e.join(id: "host", name: "Host", avatar: 0, now: 0)
        try e.join(id: "g", name: "G", avatar: 0, now: 0)
        try e.setReady("g", true)
        XCTAssertThrowsError(try e.start(by: "host", now: 0)) { XCTAssertEqual($0 as? EngineError, .notEnoughQuestions) }
    }
}

final class TeamTests: XCTestCase {
    func testPlayersAreAutoBalancedAcrossTeams() throws {
        let e = Fixtures.engine(mode: .teams, settings: MatchSettings(questionCount: 5, teamCount: 2))
        for id in ["h", "a", "b", "c", "d"] { try e.join(id: id, name: id, avatar: 0, now: 0) }
        let sizes = Dictionary(grouping: e.players, by: { $0.team ?? -1 }).mapValues(\.count)
        XCTAssertEqual(sizes[0], 3)
        XCTAssertEqual(sizes[1], 2)
    }

    func testNonHostCannotStackATeam() throws {
        let e = Fixtures.engine(mode: .teams, settings: MatchSettings(questionCount: 5, teamCount: 2))
        for id in ["h", "a", "b", "c"] { try e.join(id: id, name: id, avatar: 0, now: 0) }
        // Teams start 2–2. cap = ceil(4/2) = 2, so moving a player from team 1 to team 0 is refused.
        let mover = e.players.first { $0.team == 1 && $0.id != "h" }!.id
        XCTAssertThrowsError(try e.setTeam(by: mover, target: mover, team: 0)) {
            XCTAssertEqual($0 as? EngineError, .teamFull)
        }
        XCTAssertNoThrow(try e.setTeam(by: "h", target: mover, team: 0), "the host may arrange teams freely")
    }

    func testTeamsLockedAfterStartAndPlayersCannotMoveOthers() throws {
        let e = Fixtures.engine(mode: .teams, settings: MatchSettings(questionCount: 5, teamCount: 2))
        for id in ["h", "a", "b", "c"] { try e.join(id: id, name: id, avatar: 0, now: 0) }
        XCTAssertThrowsError(try e.setTeam(by: "a", target: "b", team: 0)) { XCTAssertEqual($0 as? EngineError, .notHost) }
        for id in ["a", "b", "c"] { try e.setReady(id, true) }
        try e.start(by: "h", now: 0)
        XCTAssertThrowsError(try e.setTeam(by: "a", target: "a", team: 1)) { XCTAssertEqual($0 as? EngineError, .notInLobby) }
    }

    func testEmptyTeamBlocksStart() throws {
        let e = Fixtures.engine(mode: .teams, settings: MatchSettings(questionCount: 5, teamCount: 3))
        for id in ["h", "a"] { try e.join(id: id, name: id, avatar: 0, now: 0) }
        try e.setReady("a", true)
        XCTAssertThrowsError(try e.start(by: "h", now: 0)) { XCTAssertEqual($0 as? EngineError, .teamEmpty) }
    }

    func testTeamScoreIsAverageAndTotalsAreConsistent() throws {
        let e = Fixtures.engine(mode: .teams, settings: MatchSettings(questionCount: 5, teamCount: 2))
        for id in ["h", "a", "b"] { try e.join(id: id, name: id, avatar: 0, now: 0) }
        // h → team 0, a → team 1, b → team 0
        for id in ["a", "b"] { try e.setReady(id, true) }
        try e.start(by: "h", now: 0)
        let open = e.timing.countdownMs
        e.tick(now: open)
        _ = try e.submit(playerId: "h", round: 1, choice: e.correctChoice(for: "h"), now: open + 10_000 - 1) // 1000
        _ = try e.submit(playerId: "b", round: 1, choice: e.wrongChoice(for: "b"), now: open + 100)            // 0
        _ = try e.submit(playerId: "a", round: 1, choice: e.correctChoice(for: "a"), now: open + 10_000 - 1)   // 1000
        let teams = e.teamStandings(includeLeft: true)
        let t0 = teams.first { $0.index == 0 }!
        let t1 = teams.first { $0.index == 1 }!
        XCTAssertEqual(t0.total, 1000)
        XCTAssertEqual(t0.score, 500)
        XCTAssertEqual(t1.score, 1000)
        XCTAssertEqual(t1.rank, 1)
        XCTAssertEqual(teams.map(\.total).reduce(0, +), e.players.map(\.score).reduce(0, +))
    }

    func testTiedTeamsShareRank() throws {
        let e = Fixtures.engine(mode: .teams, settings: MatchSettings(questionCount: 5, teamCount: 2))
        for id in ["h", "a"] { try e.join(id: id, name: id, avatar: 0, now: 0) }
        let teams = e.teamStandings(includeLeft: true)
        XCTAssertEqual(teams.map(\.rank), [1, 1])
        XCTAssertEqual(teams.map(\.index), [0, 1], "ties fall back to team order")
    }
}

/// Host and guests must be scored the same for the same reaction time, however
/// far the guest is from the host's phone.
final class FairnessTests: XCTestCase {
    private func nearbyEngine() throws -> (MatchEngine, Int64) {
        let qs = (0..<30).map { Fixtures.question($0, answer: $0 % 4) }
        let e = MatchEngine(mode: .ffa, settings: MatchSettings(questionCount: 5), code: "ABCDE", timing: .nearby, seed: 7) { _, seen, n in
            Array(qs.filter { !seen.contains($0.id) }.prefix(n))
        }
        for id in ["host", "guest", "third"] { try e.join(id: id, name: id, avatar: 0, now: 0) }
        try e.setReady("guest", true)
        try e.setReady("third", true)
        try e.start(by: "host", now: 0)
        e.tick(now: e.timing.countdownMs)
        return (e, e.rounds[0].opensAt!)
    }

    func testQuestionIsSentAheadAndRevealedAtSharedMoment() throws {
        let (e, opens) = try nearbyEngine()
        XCTAssertEqual(opens, e.timing.countdownMs + e.timing.deliveryLeadMs)
        XCTAssertEqual(e.phase, .question, "the round is published before it is revealed")
        XCTAssertEqual(try e.submit(playerId: "host", round: 1, choice: 0, now: opens - 1).status, .notActive,
                       "nobody can answer before the reveal")
    }

    func testSameReactionTimeScoresTheSameForHostAndGuest() throws {
        let (e, opens) = try nearbyEngine()
        // Both react in 2.0 s. The guest's answer spends 180 ms on the network.
        _ = try e.submit(playerId: "host", round: 1, choice: e.correctChoice(for: "host"), now: opens + 2_000)
        _ = try e.submit(playerId: "guest", round: 1, choice: e.correctChoice(for: "guest"), now: opens + 2_180,
                         reportedElapsedMs: 2_000, compensationMs: 220)
        e.tick(now: opens + 20_000)
        XCTAssertEqual(e.player("host")?.score, 1_200)
        XCTAssertEqual(e.player("guest")?.score, 1_200)
    }

    func testReportedTimeCannotUndercutTheMeasuredDelay() throws {
        let (e, opens) = try nearbyEngine()
        // Arrives 3 s after reveal claiming 0 ms; only 200 ms of credit is allowed.
        _ = try e.submit(playerId: "guest", round: 1, choice: e.correctChoice(for: "guest"), now: opens + 3_000,
                         reportedElapsedMs: 0, compensationMs: 200)
        e.tick(now: opens + 20_000)
        XCTAssertEqual(e.rounds[0].answers["guest"]?.responseMs, 2_800)
    }

    func testCompensationIsCappedByTheEngine() throws {
        let (e, opens) = try nearbyEngine()
        _ = try e.submit(playerId: "guest", round: 1, choice: 0, now: opens + 5_000,
                         reportedElapsedMs: 0, compensationMs: 99_000)
        XCTAssertEqual(e.rounds[0].answers["guest"]?.responseMs, Int(5_000 - e.timing.maxCompensationMs))
    }

    func testClaimingToBeSlowerIsIgnored() throws {
        let (e, opens) = try nearbyEngine()
        _ = try e.submit(playerId: "guest", round: 1, choice: 0, now: opens + 1_000,
                         reportedElapsedMs: 9_000, compensationMs: 200)
        XCTAssertEqual(e.rounds[0].answers["guest"]?.responseMs, 1_000)
    }

    func testGuestTapJustBeforeZeroStillCountsButHostCannotGoOver() throws {
        let (e, opens) = try nearbyEngine()
        let closes = opens + 10_000
        // Guest tapped at 9.95 s on their phone; the answer lands 150 ms after the nominal deadline.
        let g = try e.submit(playerId: "guest", round: 1, choice: e.correctChoice(for: "guest"), now: closes + 100,
                             reportedElapsedMs: 9_950, compensationMs: 200)
        XCTAssertEqual(g.status, .accepted)
        // The host has no network delay, so no grace.
        XCTAssertEqual(try e.submit(playerId: "host", round: 1, choice: 0, now: closes).status, .tooLate)
        // A guest answer whose time works out at 10 s or more is too late.
        XCTAssertEqual(try e.submit(playerId: "third", round: 1, choice: 0, now: closes + 150,
                                    reportedElapsedMs: 10_000, compensationMs: 200).status, .tooLate)
    }

    func testRoundStaysOpenForInFlightAnswersThenCloses() throws {
        let (e, opens) = try nearbyEngine()
        e.tick(now: opens + 10_000)
        XCTAssertEqual(e.phase, .question, "held open for answers still on the network")
        e.tick(now: opens + 10_000 + e.timing.maxCompensationMs)
        XCTAssertEqual(e.phase, .reveal)
    }
}
