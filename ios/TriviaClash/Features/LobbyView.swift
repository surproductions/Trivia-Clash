import SwiftUI

struct LobbyView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: GameSession
    let view: PlayerView

    @State private var editingSettings = false
    @State private var draftSettings = MatchSettings()
    @State private var draftMode: GameMode = .ffa
    @State private var confirmLeave = false
    @State private var showQR = false

    private var me: MemberView? { view.members.first { $0.id == view.me } }
    private var isHost: Bool { view.room.hostId == view.me }
    private var joinLink: String { "triviaclash://join?code=\(view.room.code)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topBar
                codeCard
                settingsSummary
                if view.room.mode == .teams { teamsSection } else { playersSection }
                Color.clear.frame(height: 90)
            }
            .padding(Theme.gutter)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $editingSettings) { settingsSheet }
        .sheet(isPresented: $showQR) { qrSheet }
        .confirmationDialog("Leave the lobby?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(isHost && session.isAuthority ? "Close room" : "Leave", role: .destructive) { app.endSession() }
        } message: {
            Text(isHost && session.isAuthority ? "Everyone in the room will be disconnected." : "You can rejoin with the code.")
        }
    }

    private var topBar: some View {
        HStack {
            Button { confirmLeave = true } label: {
                Label("Leave", systemImage: "chevron.left").font(.label(.subheadline))
            }
            .foregroundStyle(Theme.ink)
            Spacer()
            Text(view.room.mode.title).font(.label(.subheadline)).foregroundStyle(Theme.inkMuted)
        }
    }

    private var codeCard: some View {
        Panel {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Room code")
                    Text(view.room.code)
                        .font(.system(size: 44, weight: .black, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(Theme.voltInk)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .accessibilityLabel("Room code \(view.room.code.map(String.init).joined(separator: " "))")
                    Text("Friends nearby: open Trivia Clasher › Join, or scan the QR code with the Camera.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkMuted)
                    HStack(spacing: 10) {
                        ShareLink(item: "Join my Trivia Clasher game! Open the app, tap Join and enter code \(view.room.code). Link: \(joinLink)") {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button { showQR = true } label: { Label("QR", systemImage: "qrcode") }
                    }
                    .font(.label(.subheadline))
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                QRCodeView(text: joinLink)
                    .frame(width: 96, height: 96)
                    .onTapGesture { showQR = true }
            }
        }
    }

    private var settingsSummary: some View {
        let s = view.room.settings
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Match settings")
                if isHost && session.isAuthority {
                    Button("Edit") {
                        draftSettings = s
                        draftMode = view.room.mode
                        editingSettings = true
                    }
                    .font(.label(.subheadline))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(text: "\(s.questionCount) questions", symbol: "number")
                    Chip(text: s.difficulty.title, symbol: "gauge.medium")
                    Chip(text: s.categories.isEmpty ? "All categories" :
                            (s.categories.count <= 2 ? s.categories.map(\.shortTitle).joined(separator: ", ") : "\(s.categories.count) categories"),
                         symbol: "square.grid.2x2")
                    if s.finalDouble { Chip(text: "2× finale", symbol: "bolt.fill") }
                    Chip(text: "10s per question", symbol: "timer")
                }
            }
        }
    }

    private var playersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Players · \(view.members.count)/\(view.room.maxPlayers)")
            ForEach(view.members) { m in playerRow(m) }
            if view.members.count < 2 {
                Text("Waiting for at least one more player…").font(.subheadline).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private var teamsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Teams · \(view.members.count)/\(view.room.maxPlayers) players")
                if isHost && session.isAuthority {
                    Button("Shuffle") { session.shuffleTeams(); Haptics.tap() }.font(.label(.subheadline))
                }
            }
            Text("Tap a team to join it. Team score is the average of its players' points, so smaller teams aren't penalised.")
                .font(.footnote).foregroundStyle(Theme.inkMuted)
            ForEach(0..<view.room.teamCount, id: \.self) { team in
                let members = view.members.filter { $0.team == team }
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        session.setTeam(target: view.me, team: team)
                        Haptics.tap()
                    } label: {
                        HStack {
                            Circle().fill(Theme.teamColor(team)).frame(width: 14, height: 14)
                            Text("Team \(TeamStyle.name(team))").font(.display(.headline)).foregroundStyle(Theme.ink)
                            Spacer()
                            if me?.team == team {
                                Text("You're here").font(.caption).foregroundStyle(Theme.inkMuted)
                            } else {
                                Text("Join").font(.label(.subheadline)).foregroundStyle(Theme.voltInk)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Team \(TeamStyle.name(team)), \(members.count) players")
                    .accessibilityHint(me?.team == team ? "You are on this team" : "Double tap to join")
                    if members.isEmpty {
                        Text("No one yet").font(.footnote).foregroundStyle(Theme.inkMuted)
                    }
                    ForEach(members) { m in playerRow(m) }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.teamColor(team).opacity(me?.team == team ? 1 : 0), lineWidth: 2))
            }
        }
    }

    private func playerRow(_ m: MemberView) -> some View {
        HStack(spacing: 12) {
            AvatarBadge(avatar: m.avatar, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.name).font(.label(.body)).foregroundStyle(Theme.ink).lineLimit(1)
                    if m.id == view.me { Text("you").font(.caption).foregroundStyle(Theme.inkMuted) }
                }
                if m.host {
                    Label("Host", systemImage: "crown.fill").font(.caption).foregroundStyle(Theme.voltInk)
                } else if !m.connected {
                    Label("Reconnecting", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Spacer()
            if !m.host {
                Text(m.ready ? "Ready" : "Not ready")
                    .font(.label(.caption))
                    .foregroundStyle(m.ready ? Theme.onVolt : Theme.inkMuted)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(m.ready ? Theme.correct : Theme.surfaceRaised))
            }
            if isHost && session.isAuthority && m.id != view.me {
                Menu {
                    if view.room.mode == .teams {
                        ForEach(0..<view.room.teamCount, id: \.self) { t in
                            Button("Move to \(TeamStyle.name(t))") { session.setTeam(target: m.id, team: t) }
                        }
                    }
                    Button("Remove from room", role: .destructive) { session.kick(m.id) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.inkMuted)
                }
                .accessibilityLabel("Options for \(m.name)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if isHost && session.isAuthority {
                if let reason = startBlockerText {
                    Text(reason).font(.footnote).foregroundStyle(Theme.inkMuted)
                }
                Button("Start match") { session.start(); Haptics.lockIn() }
                    .buttonStyle(.primary)
                    .disabled(startBlockerText != nil)
            } else if let me {
                Button(me.ready ? "Ready — tap to undo" : "I'm ready") {
                    session.setReady(!me.ready)
                    Haptics.tap()
                }
                .buttonStyle(PrimaryButtonStyle(tint: me.ready ? Theme.correct : Theme.volt))
                Text("The host starts the match when everyone is ready.").font(.footnote).foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.background.opacity(0.96).ignoresSafeArea(edges: .bottom))
    }

    private var startBlockerText: String? {
        let active = view.members.filter { !$0.left }
        if active.count < 2 { return "Waiting for players to join." }
        let notReady = active.filter { !$0.host && !$0.ready && $0.connected }
        if !notReady.isEmpty {
            return notReady.count == 1 ? "Waiting for \(notReady[0].name) to be ready." : "Waiting for \(notReady.count) players to be ready."
        }
        if view.room.mode == .teams {
            let used = Set(active.compactMap(\.team))
            if used.count < view.room.teamCount { return "Every team needs at least one player." }
        }
        return nil
    }

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Mode", selection: $draftMode) {
                        Text(GameMode.ffa.title).tag(GameMode.ffa)
                        Text(GameMode.teams.title).tag(GameMode.teams)
                    }
                    .pickerStyle(.segmented)
                    MatchSettingsForm(settings: $draftSettings, mode: draftMode, bank: app.bank, showTeams: draftMode == .teams)
                }
                .padding(Theme.gutter)
            }
            .clashBackground()
            .navigationTitle("Match settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingSettings = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        session.updateSettings(draftSettings.sanitized(for: draftMode), mode: draftMode)
                        editingSettings = false
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var qrSheet: some View {
        VStack(spacing: 20) {
            Text("Scan to join").font(.display(.title2)).foregroundStyle(Theme.ink)
            QRCodeView(text: joinLink).frame(maxWidth: 280)
            Text(view.room.code).font(.system(size: 40, weight: .black, design: .monospaced)).tracking(6)
                .foregroundStyle(Theme.voltInk)
            Text("Players must be nearby and have Trivia Clasher installed.")
                .font(.footnote).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
            Button("Done") { showQR = false }.buttonStyle(.secondary).frame(maxWidth: 200)
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clashBackground()
        .presentationDetents([.medium, .large])
    }
}
