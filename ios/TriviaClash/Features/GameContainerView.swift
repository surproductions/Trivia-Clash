import SwiftUI

/// Routes between the match phases and owns the per-phase feedback (sounds,
/// haptics, stats recording).
struct GameContainerView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: GameSession

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let view = session.view {
                    switch view.room.status {
                    case .lobby: LobbyView(session: session, view: view)
                    case .countdown: CountdownView(session: session, view: view)
                    case .question: QuestionView(session: session, view: view).id(view.round?.no ?? 0)
                    case .reveal: RevealScreen(session: session, view: view)
                    case .finished: FinalResultsView(session: session, view: view)
                    case .closed: ClosedView(message: "This game has ended.") { app.endSession() }
                    }
                } else if case .lost(let reason) = session.connection {
                    ClosedView(message: reason) { app.endSession() }
                } else {
                    ConnectingView { app.endSession() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                if session.view != nil { ConnectionBanner(state: session.connection) }
                if let notice = session.notice {
                    Text(notice)
                        .font(.label(.footnote))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.surfaceRaised))
                        .onTapGesture { session.notice = nil }
                        .task(id: notice) {
                            try? await Task.sleep(nanoseconds: 3_500_000_000)
                            if session.notice == notice { session.notice = nil }
                        }
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .padding(.top, 6)
            .animation(.easeOut(duration: 0.2), value: session.notice)
        }
        .clashBackground()
        .onChange(of: session.view?.room.status) { old, new in
            phaseChanged(from: old, to: new)
        }
        .onChange(of: session.view?.round?.no) { _, _ in
            if session.view?.room.status == .question { SoundPlayer.shared.play(.start) }
        }
    }

    private func phaseChanged(from old: Phase?, to new: Phase?) {
        guard let view = session.view, let new else { return }
        switch new {
        case .reveal:
            if let my = view.reveal?.my {
                SoundPlayer.shared.play(my.correct ? .correct : .wrong)
                Haptics.result(my.correct)
            } else {
                SoundPlayer.shared.play(.wrong)
                Haptics.warning()
            }
        case .finished:
            app.record(finished: view, session: session)
            SoundPlayer.shared.play(.victory)
        case .question where old == .countdown:
            SoundPlayer.shared.play(.start)
        default:
            break
        }
    }
}

struct ConnectingView: View {
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large).tint(Theme.voltInk)
            Text("Joining room…").font(.display(.title3)).foregroundStyle(Theme.ink)
            Text("Stay close to the host. This usually takes a few seconds.")
                .font(.subheadline).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
            Button("Cancel", action: cancel).buttonStyle(.secondary).frame(maxWidth: 200)
        }
        .padding(Theme.gutter)
    }
}

struct ClosedView: View {
    let message: String
    let done: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text("Game over").font(.display(.title2)).foregroundStyle(Theme.ink)
            Text(message).font(.body).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
            Button("Back to home", action: done).buttonStyle(.primary)
        }
        .padding(Theme.gutter)
    }
}

// MARK: - Shared bits

/// Header used during play: progress, category and a leave button.
struct MatchHeader: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: GameSession
    let view: PlayerView
    @State private var confirmLeave = false

    var body: some View {
        HStack(spacing: 10) {
            Button { confirmLeave = true } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .accessibilityLabel("Leave game")
            if let round = view.round {
                Text("Q\(round.no) of \(round.total)").font(.numeric(.subheadline)).foregroundStyle(Theme.ink)
                Chip(text: round.category.shortTitle, symbol: round.category.symbol)
                if round.multiplier > 1 { Chip(text: "2× points", symbol: "bolt.fill") }
            }
            Spacer()
            if let me = view.members.first(where: { $0.id == view.me }) {
                Text(Format.points(me.score)).font(.numeric(.headline)).foregroundStyle(Theme.voltInk)
                    .accessibilityLabel("Your score \(me.score)")
            }
        }
        .confirmationDialog(leaveTitle, isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(session.isAuthority && view.room.mode != .solo ? "End game for everyone" : "Leave game", role: .destructive) {
                app.endSession()
            }
        } message: {
            Text(leaveMessage)
        }
    }

    private var leaveTitle: String { "Leave this game?" }
    private var leaveMessage: String {
        if view.room.mode == .solo { return "Your progress in this game will be lost." }
        if session.isAuthority { return "You're the host. Leaving ends the game for everyone nearby." }
        return "You can rejoin with the same code while the game is running."
    }
}

struct MiniStandings: View {
    let view: PlayerView
    var limit = 5

    var body: some View {
        VStack(spacing: 6) {
            if let teams = view.teams {
                ForEach(teams) { team in
                    HStack {
                        Text(Format.ordinal(team.rank)).font(.numeric(.footnote)).foregroundStyle(Theme.inkMuted).frame(width: 34, alignment: .leading)
                        Circle().fill(Theme.teamColor(team.index)).frame(width: 12, height: 12)
                        Text("Team \(TeamStyle.name(team.index))").font(.label(.subheadline)).foregroundStyle(Theme.ink)
                        Text("· \(team.size)").font(.caption).foregroundStyle(Theme.inkMuted)
                        Spacer()
                        Text(Format.points(team.score)).font(.numeric(.subheadline)).foregroundStyle(Theme.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider().overlay(Theme.stroke).padding(.vertical, 4)
            }
            ForEach(rows) { m in
                HStack(spacing: 10) {
                    Text(Format.ordinal(m.rank)).font(.numeric(.footnote)).foregroundStyle(Theme.inkMuted).frame(width: 34, alignment: .leading)
                    AvatarBadge(avatar: m.avatar, size: 24)
                    Text(m.name).font(.label(.subheadline)).foregroundStyle(m.id == view.me ? Theme.voltInk : Theme.ink).lineLimit(1)
                    if let team = m.team, view.teams != nil { Circle().fill(Theme.teamColor(team)).frame(width: 8, height: 8) }
                    if m.left { Text("left").font(.caption2).foregroundStyle(Theme.inkMuted) }
                    Spacer()
                    if view.room.status == .reveal, m.lastPoints > 0 {
                        Text("+\(Format.points(m.lastPoints))").font(.numeric(.caption)).foregroundStyle(Theme.correct)
                    }
                    Text(Format.points(m.score)).font(.numeric(.subheadline)).foregroundStyle(Theme.ink)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Top players plus me, if I'm further down.
    private var rows: [MemberView] {
        var top = Array(view.members.prefix(limit))
        if !top.contains(where: { $0.id == view.me }), let me = view.members.first(where: { $0.id == view.me }) {
            top.append(me)
        }
        return top
    }
}
