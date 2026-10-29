import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirmReset = false
    @State private var confirmStats = false

    var body: some View {
        Form {
            Section("Feedback") {
                Toggle("Sound effects", isOn: $app.preferences.soundOn)
                Toggle("Haptics", isOn: $app.preferences.hapticsOn)
            }
            Section {
                Picker("Appearance", selection: $app.preferences.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Animations follow your device's Reduce Motion setting.")
            }
            Section {
                LabeledContent("Questions", value: "\(app.bank?.questions.count ?? 0)")
                LabeledContent("Categories", value: "\(TriviaCategory.allCases.count)")
                if let verified = app.bank?.verifiedOn, !verified.isEmpty {
                    LabeledContent("Last reviewed", value: verified)
                }
            } header: {
                Text("Question bank")
            } footer: {
                Text("Every question includes an explanation and a reference link shown after the round. Answers are stored encrypted in the app and only revealed when a round closes.")
            }
            Section {
                Text("Trivia Clasher has no accounts, ads or tracking. Your name, badge, settings and stats stay on this phone. In nearby games, your name and badge are shared only with players in the same room over a direct, encrypted local connection.")
                    .font(.footnote)
                Button("Reset statistics") { confirmStats = true }
                Button("Delete all my data", role: .destructive) { confirmReset = true }
            } header: {
                Text("Privacy")
            }
            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
            } header: {
                Text("About")
            }
        }
        .scrollContentBackground(.hidden)
        .clashBackground()
        .navigationTitle("Settings")
        .confirmationDialog("Reset your statistics?", isPresented: $confirmStats, titleVisibility: .visible) {
            Button("Reset statistics", role: .destructive) { app.resetStats() }
        }
        .confirmationDialog("Delete all data on this phone?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { app.resetAllData() }
        } message: {
            Text("This removes your name, badge, settings, stats and question history. It can't be undone.")
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let profile = app.profile {
                ProfileEditor(title: "Your profile", buttonTitle: "Save", initialName: profile.name,
                              initialAvatar: profile.avatar) { name, avatar in
                    app.saveProfile(name: name, avatar: avatar)
                    dismiss()
                }
                statsPanel.padding(.horizontal, Theme.gutter).padding(.bottom, 20)
            }
        }
        .clashBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statsPanel: some View {
        let s = app.stats
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Stats")
                LabeledContent("Solo games", value: "\(s.gamesPlayed)")
                LabeledContent("Nearby games", value: "\(s.multiplayerGames) · \(s.multiplayerWins) won")
                LabeledContent("Accuracy", value: s.questionsAnswered == 0 ? "—" : Format.percent(s.accuracy))
                LabeledContent("Best streak", value: "\(s.bestStreak)")
                ForEach(MatchSettings.soloLengths, id: \.self) { n in
                    LabeledContent("Best score (\(n))", value: s.bestScores["\(n)"].map(Format.points) ?? "—")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.ink)
        }
    }
}

extension Bundle {
    var versionString: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
