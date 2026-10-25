import SwiftUI

enum HomeRoute: Hashable {
    case solo, host, join, settings, profile
}

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @State private var path: [HomeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    VStack(spacing: 12) {
                        modeCard(route: .solo, symbol: "person.fill", title: "Solo",
                                 subtitle: "Beat your best score. Works offline.", primary: true)
                        modeCard(route: .host, symbol: "dot.radiowaves.left.and.right", title: "Host a game",
                                 subtitle: "Friends nearby join with your room code.")
                        modeCard(route: .join, symbol: "keyboard", title: "Join a game",
                                 subtitle: "Enter a code or pick a room nearby.")
                    }
                    statsStrip
                    rules
                }
                .padding(Theme.gutter)
            }
            .clashBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path.append(.settings) } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .solo: SoloSetupView()
                case .host: HostSetupView()
                case .join: JoinView()
                case .settings: SettingsView()
                case .profile: ProfileView()
                }
            }
        }
        .tint(Theme.voltInk)
        .onChange(of: app.showJoin) { _, show in
            if show {
                app.showJoin = false
                path = [.join]
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Wordmark(size: .title2)
            Spacer()
            if let profile = app.profile {
                Button { path.append(.profile) } label: {
                    HStack(spacing: 8) {
                        Text(profile.name).font(.label(.subheadline)).foregroundStyle(Theme.ink).lineLimit(1)
                        AvatarBadge(avatar: profile.avatar, size: 34)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile, \(profile.name)")
            }
        }
        .padding(.top, 8)
    }

    private func modeCard(route: HomeRoute, symbol: String, title: String, subtitle: String, primary: Bool = false) -> some View {
        Button { path.append(route) } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(primary ? Theme.onVolt.opacity(0.12) : Theme.surfaceRaised))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.display(.title3))
                    Text(subtitle).font(.subheadline).opacity(0.8)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.headline)
            }
            .foregroundStyle(primary ? Theme.onVolt : Theme.ink)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(primary ? Theme.volt : Theme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var statsStrip: some View {
        let s = app.stats
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Your record")
            HStack(spacing: 10) {
                stat(value: s.bestScores["10"].map(Format.points) ?? "—", label: "Best (10)")
                stat(value: s.questionsAnswered == 0 ? "—" : Format.percent(s.accuracy), label: "Accuracy")
                stat(value: "\(s.bestStreak)", label: "Best streak")
                stat(value: "\(s.multiplayerWins)", label: "Wins")
            }
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.numeric(.title3)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(Theme.inkMuted).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "How scoring works")
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    rule("checkmark", "1,000 for a correct answer")
                    rule("bolt.fill", "Up to +250 for answering fast")
                    rule("flame.fill", "+50 per answer in a streak (max +200)")
                    rule("timer", "10 seconds per question. First answer is final.")
                }
            }
        }
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.voltInk).frame(width: 22).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(Theme.ink)
        }
    }
}
