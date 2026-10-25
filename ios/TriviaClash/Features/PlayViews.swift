import SwiftUI

// MARK: - Countdown

struct CountdownView: View {
    @ObservedObject var session: GameSession
    let view: PlayerView
    @State private var lastSecond = -1

    var body: some View {
        VStack(spacing: 24) {
            MatchHeader(session: session, view: view)
            Spacer()
            Text(view.room.matchNo > 1 ? "Rematch" : "Get ready")
                .font(.display(.title2))
                .foregroundStyle(Theme.inkMuted)
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let remaining = session.remainingMs(until: view.room.phaseEndsAt, now: Monotonic.nowMs())
                let seconds = max(1, Int((remaining + 999) / 1000))
                Text("\(seconds)")
                    .font(.system(size: 140, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.voltInk)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Starting in \(seconds)")
                    .onChange(of: seconds) { _, s in
                        if s != lastSecond { lastSecond = s; SoundPlayer.shared.play(.tick) }
                    }
            }
            Text("\(view.room.totalRounds) questions · 10 seconds each")
                .font(.subheadline)
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            Spacer()
        }
        .padding(Theme.gutter)
    }
}

// MARK: - Question

struct QuestionView: View {
    @ObservedObject var session: GameSession
    let view: PlayerView
    @State private var lastTickSecond = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let round = view.round {
            VStack(alignment: .leading, spacing: 18) {
                MatchHeader(session: session, view: view)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { _ in
                    let remaining = session.remainingMs(until: round.closesAt, now: Monotonic.nowMs())
                    HStack(alignment: .center, spacing: 16) {
                        CountdownRing(remainingMs: remaining)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(round.difficulty.title.uppercased())
                                .font(.label(.caption2)).tracking(1.2).foregroundStyle(Theme.inkMuted)
                            ProgressView(value: Double(remaining), total: 10_000)
                                .tint(remaining <= 3_000 ? Theme.wrong : Theme.voltInk)
                                .accessibilityHidden(true)
                            Text(statusLine(round))
                                .font(.footnote)
                                .foregroundStyle(Theme.inkMuted)
                        }
                    }
                    .onChange(of: Int((remaining + 999) / 1000)) { _, s in urgency(s) }
                }

                Text(round.prompt)
                    .font(.system(.title2, design: .default).weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 10) {
                    ForEach(Array(round.options.enumerated()), id: \.offset) { i, option in
                        AnswerButton(index: i, text: option, state: state(for: i)) {
                            choose(i)
                        }
                        .disabled(session.pendingChoice != nil)
                    }
                }
                Spacer(minLength: 0)
                if session.pendingChoice != nil {
                    lockedBanner(round)
                }
            }
            .padding(Theme.gutter)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: session.pendingChoice)
        }
    }

    private func state(for i: Int) -> AnswerState {
        guard let chosen = session.pendingChoice else { return .idle }
        return chosen == i ? .chosen : .dimmed
    }

    private func choose(_ i: Int) {
        guard session.pendingChoice == nil else { return }
        Haptics.lockIn()
        SoundPlayer.shared.play(.submit)
        session.submit(choice: i)
    }

    private func statusLine(_ round: RoundView) -> String {
        if view.room.mode == .solo { return session.pendingChoice == nil ? "Answer before time runs out" : "Locked in" }
        let active = view.members.filter { !$0.left }.count
        return "\(round.answeredCount) of \(active) locked in"
    }

    private func urgency(_ seconds: Int) {
        guard session.pendingChoice == nil, seconds <= 3, seconds >= 1, seconds < lastTickSecond else { return }
        lastTickSecond = seconds
        SoundPlayer.shared.play(.tick)
        Haptics.tap()
    }

    private func lockedBanner(_ round: RoundView) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("Answer locked in").font(.label(.subheadline))
                Text(view.room.mode == .solo ? "The answer is revealed when the round closes."
                     : "Results appear when everyone answers or time runs out.")
                    .font(.caption)
                    .opacity(0.8)
            }
            Spacer()
        }
        .foregroundStyle(Theme.ink)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.surfaceRaised))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reveal

struct RevealScreen: View {
    @ObservedObject var session: GameSession
    let view: PlayerView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MatchHeader(session: session, view: view)
                if let round = view.round, let reveal = view.reveal {
                    verdict(reveal)
                    Text(round.prompt)
                        .font(.label(.title3))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 8) {
                        ForEach(Array(round.options.enumerated()), id: \.offset) { i, option in
                            AnswerButton(index: i, text: option, state: state(for: i, reveal: reveal, round: round),
                                         count: view.room.mode == .solo ? nil : reveal.distribution[safe: i]) {}
                                .allowsHitTesting(false)
                        }
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Why", systemImage: "info.circle.fill").font(.label(.subheadline)).foregroundStyle(Theme.voltInk)
                            Text(reveal.explanation).font(.body).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = URL(string: reveal.source) {
                                Link("Source", destination: url).font(.footnote)
                            }
                        }
                    }
                    if view.room.mode != .solo {
                        SectionLabel(text: "Standings")
                        Panel { MiniStandings(view: view) }
                    }
                }
                Color.clear.frame(height: 80)
            }
            .padding(Theme.gutter)
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func state(for i: Int, reveal: RevealView, round: RoundView) -> AnswerState {
        if i == reveal.correctChoice { return .correct }
        if i == round.myChoice { return .wrong }
        return .revealedOther
    }

    @ViewBuilder
    private func verdict(_ reveal: RevealView) -> some View {
        let me = view.members.first { $0.id == view.me }
        if let my = reveal.my {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(my.correct ? "Correct!" : "Not quite")
                        .font(.display(.largeTitle))
                        .foregroundStyle(my.correct ? Theme.correct : Theme.wrong)
                    Spacer()
                    Text("+\(Format.points(my.points))").font(.numeric(.title)).foregroundStyle(Theme.ink)
                }
                if my.correct {
                    HStack(spacing: 8) {
                        Chip(text: "Base \(Format.points(my.base))")
                        Chip(text: "Speed +\(my.speed)", symbol: "bolt.fill")
                        if my.streakBonus > 0 { Chip(text: "Streak +\(my.streakBonus)", symbol: "flame.fill") }
                        if (view.round?.multiplier ?? 1) > 1 { Chip(text: "×2") }
                    }
                }
                Text(streakLine(me: me, correct: my.correct, responseMs: my.responseMs))
                    .font(.footnote).foregroundStyle(Theme.inkMuted)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Time's up").font(.display(.largeTitle)).foregroundStyle(Theme.warning)
                Text("No answer this round — 0 points, and streaks reset.").font(.footnote).foregroundStyle(Theme.inkMuted)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func streakLine(me: MemberView?, correct: Bool, responseMs: Int) -> String {
        let time = "Answered in \(Format.seconds(responseMs))."
        guard correct, let streak = me?.streak, streak >= 2 else { return correct ? time : "\(time) Streak reset." }
        return "\(time) \(streak) in a row!"
    }

    private var footer: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let remaining = session.remainingMs(until: view.room.phaseEndsAt, now: Monotonic.nowMs())
                if view.room.mode == .solo {
                    Button(isLast ? "See results" : "Next question") { session.skipReveal() }
                        .buttonStyle(.primary)
                } else {
                    Text(isLast ? "Final results in \(Int((remaining + 999) / 1000))s" : "Next question in \(Int((remaining + 999) / 1000))s")
                        .font(.label(.subheadline))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        .background(Theme.background.opacity(0.96).ignoresSafeArea(edges: .bottom))
    }

    private var isLast: Bool { view.room.currentRound >= view.room.totalRounds }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Final results

struct FinalResultsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: GameSession
    let view: PlayerView

    private var me: MemberView? { view.members.first { $0.id == view.me } }
    private var winners: [MemberView] { view.members.filter { $0.rank == 1 && !$0.left } }
    private var winningTeams: [TeamView] { (view.teams ?? []).filter { $0.rank == 1 } }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headline
                    if view.room.mode == .solo { soloSummary } else { podium }
                    if let teams = view.teams { teamBreakdown(teams) }
                    if view.room.mode != .solo {
                        SectionLabel(text: "Final standings")
                        VStack(spacing: 8) { ForEach(view.members) { playerCard($0) } }
                    }
                    Color.clear.frame(height: 120)
                }
                .padding(Theme.gutter)
            }
            ConfettiBurst().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) { actions }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match complete").font(.label(.subheadline)).foregroundStyle(Theme.inkMuted).textCase(.uppercase)
            Group {
                if view.room.mode == .solo {
                    Text(Format.points(me?.score ?? 0)).font(.system(size: 64, weight: .black, design: .rounded))
                } else if view.room.mode == .teams, !winningTeams.isEmpty {
                    Text(winningTeams.count > 1 ? "It's a tie!" : "Team \(TeamStyle.name(winningTeams[0].index)) wins!")
                        .font(.display(.largeTitle))
                } else if winners.count > 1 {
                    Text("Shared victory!").font(.display(.largeTitle))
                } else if let w = winners.first {
                    Text(w.id == view.me ? "You win!" : "\(w.name) wins!").font(.display(.largeTitle))
                }
            }
            .foregroundStyle(Theme.voltInk)
            .minimumScaleFactor(0.5)
            .lineLimit(2)
            .accessibilityAddTraits(.isHeader)
            if view.room.mode == .solo, let best = app.stats.bestScores["\(view.room.totalRounds)"], let score = me?.score {
                Text(score >= best ? "New personal best!" : "Personal best: \(Format.points(best))")
                    .font(.label(.headline)).foregroundStyle(Theme.ink)
            }
        }
    }

    private var soloSummary: some View {
        let m = me
        let accuracy = (m?.correct ?? 0) * 100 / max(1, view.room.totalRounds)
        return HStack(spacing: 10) {
            summaryStat("\(m?.correct ?? 0)/\(view.room.totalRounds)", "Correct")
            summaryStat("\(accuracy)%", "Accuracy")
            summaryStat("\(m?.bestStreak ?? 0)", "Best streak")
            summaryStat(Format.seconds(m?.fastestMs), "Fastest")
        }
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.numeric(.title3)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
    }

    private var podium: some View {
        let top = Array(view.members.filter { !$0.left }.prefix(3))
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(top.enumerated()), id: \.element.id) { n, m in
                VStack(spacing: 8) {
                    AvatarBadge(avatar: m.avatar, size: n == 0 ? 56 : 44)
                    Text(m.name).font(.label(.footnote)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Text(Format.points(m.score)).font(.numeric(.footnote)).foregroundStyle(Theme.inkMuted)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(m.rank == 1 ? Theme.volt : Theme.surfaceRaised)
                        .frame(height: m.rank == 1 ? 90 : (m.rank == 2 ? 64 : 44))
                        .overlay(Text(Format.ordinal(m.rank)).font(.display(.headline))
                            .foregroundStyle(m.rank == 1 ? Theme.onVolt : Theme.ink))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func teamBreakdown(_ teams: [TeamView]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Teams")
            ForEach(teams) { team in
                let members = view.members.filter { $0.team == team.index }
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(Format.ordinal(team.rank)).font(.numeric(.headline)).foregroundStyle(Theme.inkMuted)
                            Circle().fill(Theme.teamColor(team.index)).frame(width: 14, height: 14)
                            Text("Team \(TeamStyle.name(team.index))").font(.display(.headline)).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(Format.points(team.score)).font(.numeric(.headline)).foregroundStyle(Theme.ink)
                        }
                        Text("Average of \(team.size) players · \(Format.points(team.total)) total · \(team.correct) correct")
                            .font(.caption).foregroundStyle(Theme.inkMuted)
                        ForEach(members) { m in
                            HStack {
                                Text(m.name).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer()
                                Text(contribution(m, team: team)).font(.numeric(.caption)).foregroundStyle(Theme.inkMuted)
                            }
                        }
                    }
                }
            }
        }
    }

    private func contribution(_ m: MemberView, team: TeamView) -> String {
        guard team.total > 0 else { return "0 pts" }
        return "\(Format.points(m.score)) pts · \(m.score * 100 / team.total)%"
    }

    private func playerCard(_ m: MemberView) -> some View {
        let accuracy = m.answered == 0 ? 0 : m.correct * 100 / max(1, view.room.totalRounds)
        return HStack(spacing: 12) {
            Text(Format.ordinal(m.rank)).font(.numeric(.headline)).foregroundStyle(Theme.inkMuted).frame(width: 40, alignment: .leading)
            AvatarBadge(avatar: m.avatar, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.label(.body)).foregroundStyle(m.id == view.me ? Theme.voltInk : Theme.ink).lineLimit(1)
                Text("\(m.correct)/\(view.room.totalRounds) correct · \(accuracy)% · best streak \(m.bestStreak) · fastest \(Format.seconds(m.fastestMs))")
                    .font(.caption).foregroundStyle(Theme.inkMuted).lineLimit(2)
            }
            Spacer()
            Text(Format.points(m.score)).font(.numeric(.headline)).foregroundStyle(Theme.ink)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if view.room.mode == .solo, let solo = session as? SoloSession {
                Button("Play again") { solo.playAgain() }.buttonStyle(.primary)
                Button("New match") { app.endSession() }.buttonStyle(.secondary)
            } else if session.isAuthority && session.isHost {
                Button("Rematch — same players") { session.rematch() }.buttonStyle(.primary)
                Button("End and return home") { app.endSession() }.buttonStyle(.secondary)
            } else {
                Text("Waiting for the host to start a rematch…").font(.footnote).foregroundStyle(Theme.inkMuted)
                Button("Leave") { app.endSession() }.buttonStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .background(Theme.background.opacity(0.96).ignoresSafeArea(edges: .bottom))
    }
}
