import XCTest
@testable import TriviaClash

final class QuestionBankTests: XCTestCase {
    private func bundled() throws -> QuestionBank {
        try QuestionBank.loadBundled(from: Bundle(for: AppState.self))
    }

    func testBundledBankDecryptsAndIsValid() throws {
        let bank = try bundled()
        XCTAssertGreaterThanOrEqual(bank.questions.count, 1000)
        XCTAssertEqual(Set(bank.questions.map(\.id)).count, bank.questions.count, "ids must be unique")
        XCTAssertEqual(Set(bank.questions.map { $0.prompt.lowercased() }).count, bank.questions.count, "prompts must be unique")
        for q in bank.questions {
            XCTAssertEqual(q.options.count, 4, q.id)
            XCTAssertTrue((0..<4).contains(q.answer), q.id)
            XCTAssertEqual(Set(q.options.map { $0.lowercased() }).count, 4, "duplicate options in \(q.id)")
            XCTAssertFalse(q.explanation.isEmpty, q.id)
            XCTAssertTrue(q.source.hasPrefix("https://"), q.id)
            XCTAssertTrue(q.id.hasPrefix(q.category.rawValue + "-"), q.id)
        }
    }

    func testEveryCategoryHasEnoughQuestionsForEveryDifficulty() throws {
        let bank = try bundled()
        for cat in TriviaCategory.allCases {
            XCTAssertGreaterThanOrEqual(bank.count(in: cat), 50, cat.rawValue)
            for d in DifficultyFilter.allCases {
                XCTAssertGreaterThanOrEqual(bank.count(in: cat, difficulty: d), 3, "\(cat.rawValue) \(d.rawValue)")
            }
        }
    }

    func testAnswersAreNotAlwaysInTheSamePosition() throws {
        let positions = Set(try bundled().questions.map(\.answer))
        XCTAssertEqual(positions, [0, 1, 2, 3])
    }

    func testTamperedBundleIsRejected() throws {
        guard let url = Bundle(for: AppState.self).url(forResource: "questions", withExtension: "bin") else {
            return XCTFail("bundle missing")
        }
        var data = try Data(contentsOf: url)
        data[data.count / 2] ^= 0xFF
        XCTAssertThrowsError(try QuestionBank.decode(encrypted: data))
    }

    func testPickRespectsCategoryAndDifficulty() {
        let bank = Fixtures.bank(160)
        var rng = SplitMix64(seed: 3)
        let settings = MatchSettings(questionCount: 5, categories: [.science, .history], difficulty: .medium)
        let picked = bank.pick(settings: settings, seen: [], count: 5, using: &rng)
        XCTAssertFalse(picked.isEmpty)
        XCTAssertTrue(picked.allSatisfy { [.science, .history].contains($0.category) && $0.difficulty == .medium })
    }

    func testPickPrefersUnseenQuestionsAndHasNoDuplicates() {
        let bank = Fixtures.bank(64)
        var rng = SplitMix64(seed: 9)
        let seen = Set(bank.questions.prefix(50).map(\.id))
        let picked = bank.pick(settings: MatchSettings(questionCount: 20), seen: seen, count: 20, using: &rng)
        XCTAssertEqual(picked.count, 20)
        XCTAssertEqual(Set(picked.map(\.id)).count, 20)
        XCTAssertEqual(picked.filter { !seen.contains($0.id) }.count, 14, "all 14 unseen questions come first")
    }

    func testMixedPickSpreadsAcrossCategories() {
        let bank = Fixtures.bank(320)
        var rng = SplitMix64(seed: 5)
        let picked = bank.pick(settings: MatchSettings(questionCount: 16), seen: [], count: 16, using: &rng)
        XCTAssertEqual(Set(picked.map(\.category)).count, 16)
    }
}

final class WireProtocolTests: XCTestCase {
    func testClientMessagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .hello(playerId: "p", name: "Sam", avatar: 3, seen: ["a", "b"], protocolVersion: 1),
            .setReady(ready: true), .setTeam(target: "p", team: 2), .submit(round: 4, choice: 1),
            .ping(sentAt: 123), .leave(reason: "bye"),
        ]
        for m in messages {
            let data = try XCTUnwrap(WireProtocol.encode(m))
            XCTAssertEqual(WireProtocol.decode(ClientMessage.self, from: data), m)
        }
    }

    func testHostStateMessageCarriesNoAnswerBeforeClose() throws {
        let e = Fixtures.engine()
        let open = try e.startStandard(["host", "guest"])
        let message = HostMessage.state(view: e.view(for: "guest", now: open + 50))
        let data = try XCTUnwrap(WireProtocol.encode(message))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("correctChoice"))
        XCTAssertFalse(json.contains("explanation"))
        XCTAssertEqual(WireProtocol.decode(HostMessage.self, from: data), message)
    }

    func testGarbageIsIgnored() {
        XCTAssertNil(WireProtocol.decode(ClientMessage.self, from: Data("{\"nope\":1}".utf8)))
    }
}

final class ClockSyncTests: XCTestCase {
    private func view(serverNow: Int64, version: Int = 2) -> PlayerView {
        PlayerView(serverNow: serverNow, version: version, me: "me",
                   room: RoomInfo(id: "r", code: "ABCDE", mode: .ffa, status: .question, hostId: "h", questionCount: 10,
                                  totalRounds: 10, categories: [], difficulty: .mixed, teamCount: 2, finalDouble: false,
                                  matchNo: 1, currentRound: 1, phaseEndsAt: serverNow + 10_000, maxPlayers: 12),
                   members: [], teams: nil, round: nil, reveal: nil)
    }

    func testDeadlineIsMappedToLocalClockWithLatencyCorrection() {
        let session = GameSession(myId: "me")
        session.oneWayLatencyMs = 40
        // Host clock says 1,000,000; we receive it at our local 5,000.
        session.apply(view(serverNow: 1_000_000), receivedAt: 5_000)
        // The host deadline is 10 s after its "now". Locally the countdown ends 2 × 40 ms earlier:
        // the view took ~40 ms to arrive, and an answer needs ~40 ms to get back.
        XCTAssertEqual(session.remainingMs(until: 1_010_000, now: 5_000), 9_920)
        XCTAssertEqual(session.remainingMs(until: 1_010_000, now: 14_920), 0)
        XCTAssertEqual(session.remainingMs(until: 1_010_000, now: 20_000), 0, "never negative")
    }

    func testStaleViewsAreIgnored() {
        let session = GameSession(myId: "me")
        session.apply(view(serverNow: 100, version: 5), receivedAt: 0)
        session.apply(view(serverNow: 50, version: 4), receivedAt: 10)
        XCTAssertEqual(session.view?.version, 5)
    }
}

final class ProfileTests: XCTestCase {
    func testNamesAreCleanedAndValidated() {
        XCTAssertEqual(Profile.clean("  Ada   Lovelace  "), "Ada Lovelace")
        XCTAssertEqual(Profile.clean("ABCDEFGHIJKLMNOPQRST"), "ABCDEFGHIJKLMNOP")
        XCTAssertFalse(Profile.isValid("A"))
        XCTAssertTrue(Profile.isValid("Al"))
        XCTAssertFalse(Profile.isValid("shitlord"))
    }
}
