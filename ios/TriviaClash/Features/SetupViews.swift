import SwiftUI

/// Category tiles + difficulty + length, shared by solo setup, host setup and the lobby.
struct MatchSettingsForm: View {
    @Binding var settings: MatchSettings
    let mode: GameMode
    let bank: QuestionBank?
    var showTeams: Bool = false

    private var lengths: [Int] { mode == .solo ? MatchSettings.soloLengths : MatchSettings.partyLengths }
    private var available: Int { bank?.available(for: settings) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Categories")
                    Spacer()
                    Button("Surprise me") {
                        settings.categories = Array(TriviaCategory.allCases.shuffled().prefix(3))
                        Haptics.tap()
                    }
                    .font(.label(.caption))
                    Button(settings.categories.isEmpty ? "All on" : "Mix all") {
                        settings.categories = []
                        Haptics.tap()
                    }
                    .font(.label(.caption))
                    .disabled(settings.categories.isEmpty)
                }
                CategoryGrid(selected: $settings.categories, bank: bank, difficulty: settings.difficulty)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Difficulty")
                Picker("Difficulty", selection: $settings.difficulty) {
                    ForEach(DifficultyFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Questions")
                Picker("Questions", selection: $settings.questionCount) {
                    ForEach(lengths, id: \.self) { n in
                        Text(mode == .solo && n == 30 ? "30 · Extended" : "\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
            }

            if showTeams {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Teams")
                    Picker("Teams", selection: $settings.teamCount) {
                        ForEach(2...4, id: \.self) { Text("\($0) teams").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Toggle(isOn: $settings.finalDouble) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Double-points finale").font(.label(.body)).foregroundStyle(Theme.ink)
                    Text("The last question is worth twice as much.").font(.footnote).foregroundStyle(Theme.inkMuted)
                }
            }
            .tint(Theme.voltInk)

            if available < settings.questionCount {
                Label(available < 3 ? "Not enough questions for this combination." :
                        "Only \(available) questions match — the match will be shorter.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
    }
}

struct CategoryGrid: View {
    @Binding var selected: [TriviaCategory]
    let bank: QuestionBank?
    let difficulty: DifficultyFilter

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(TriviaCategory.allCases) { cat in
                let isOn = selected.isEmpty || selected.contains(cat)
                let count = bank?.count(in: cat, difficulty: difficulty) ?? 0
                Button {
                    toggle(cat)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: cat.symbol).font(.system(size: 20, weight: .bold))
                        Text(cat.title)
                            .font(.label(.footnote))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text("\(count) Qs").font(.caption2).opacity(0.7)
                    }
                    .foregroundStyle(isOn ? Theme.onVolt : Theme.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isOn ? Theme.volt : Theme.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cat.title)
                .accessibilityValue(isOn ? "Included, \(count) questions" : "Excluded")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    /// Empty selection means "all". Tapping a tile while everything is on
    /// switches to just that category; deselecting the last one returns to all.
    private func toggle(_ cat: TriviaCategory) {
        Haptics.tap()
        if selected.isEmpty {
            selected = [cat]
        } else if let i = selected.firstIndex(of: cat) {
            selected.remove(at: i)
        } else {
            selected.append(cat)
            if selected.count == TriviaCategory.allCases.count { selected = [] }
        }
    }
}

struct SoloSetupView: View {
    @EnvironmentObject private var app: AppState
    @State private var settings = MatchSettings()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Solo").font(.display(.largeTitle)).foregroundStyle(Theme.ink)
                MatchSettingsForm(settings: $settings, mode: .solo, bank: app.bank)
                bestScore
                Button("Start") { app.startSolo(settings: settings.sanitized(for: .solo)) }
                    .buttonStyle(.primary)
                    .disabled((app.bank?.available(for: settings) ?? 0) < 3)
            }
            .padding(Theme.gutter)
        }
        .clashBackground()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            settings = app.store.lastSoloSettings.sanitized(for: .solo)
        }
    }

    private var bestScore: some View {
        let best = app.stats.bestScores["\(settings.questionCount)"]
        return HStack {
            Image(systemName: "trophy.fill").foregroundStyle(Theme.voltInk)
            Text(best.map { "Personal best for \(settings.questionCount): \(Format.points($0))" } ?? "No best score yet for \(settings.questionCount) questions.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkMuted)
        }
    }
}

struct HostSetupView: View {
    @EnvironmentObject private var app: AppState
    @State private var mode: GameMode = .ffa
    @State private var settings = MatchSettings()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Host a game").font(.display(.largeTitle)).foregroundStyle(Theme.ink)
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Players join from their own phones nearby (Wi-Fi or Bluetooth). Keep the app open while you host.",
                              systemImage: "dot.radiowaves.left.and.right")
                        Label("Up to 12 players.", systemImage: "person.3.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Mode")
                    Picker("Mode", selection: $mode) {
                        Text(GameMode.ffa.title).tag(GameMode.ffa)
                        Text(GameMode.teams.title).tag(GameMode.teams)
                    }
                    .pickerStyle(.segmented)
                }
                MatchSettingsForm(settings: $settings, mode: mode, bank: app.bank, showTeams: mode == .teams)
                Button("Open room") { app.host(mode: mode, settings: settings.sanitized(for: mode)) }
                    .buttonStyle(.primary)
                    .disabled((app.bank?.available(for: settings) ?? 0) < 3)
            }
            .padding(Theme.gutter)
        }
        .clashBackground()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            settings = app.store.lastPartySettings.sanitized(for: .ffa)
        }
    }
}

struct JoinView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var browser: NearbyBrowser
    @State private var code = ""
    @State private var waitingForCode = false
    @FocusState private var codeFocused: Bool

    init() {
        _browser = StateObject(wrappedValue: NearbyBrowser(profile: LocalStore.shared.profile
            ?? Profile(id: UUID().uuidString, name: "Player", avatar: 0)))
    }

    private var normalized: String { RoomCode.normalize(code) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Join a game").font(.display(.largeTitle)).foregroundStyle(Theme.ink)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Room code")
                    TextField("ABCDE", text: $code)
                        .font(.system(.largeTitle, design: .monospaced).weight(.heavy))
                        .tracking(8)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.join)
                        .focused($codeFocused)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
                        .onChange(of: code) { _, value in
                            let n = RoomCode.normalize(value)
                            if n != value { code = n }
                        }
                        .onSubmit(joinByCode)
                        .accessibilityLabel("Room code, 5 characters")
                    Text("Codes never use O, 0, I, 1 or L, so there's nothing to mix up.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkMuted)
                    Button(waitingForCode ? "Looking for \(normalized)…" : "Join") { joinByCode() }
                        .buttonStyle(.primary)
                        .disabled(!RoomCode.isValid(normalized) || waitingForCode)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(text: "Nearby rooms")
                        ProgressView().controlSize(.small)
                    }
                    if let error = browser.error {
                        Label(error, systemImage: "lock.shield").font(.footnote).foregroundStyle(Theme.warning)
                    }
                    if browser.rooms.isEmpty {
                        Text("Searching for games hosted nearby… Make sure Wi-Fi or Bluetooth is on.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkMuted)
                            .padding(.vertical, 8)
                    }
                    ForEach(browser.rooms) { room in
                        Button { join(room) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(room.hostName)'s room").font(.label(.body)).foregroundStyle(Theme.ink)
                                    Text(room.code).font(.system(.subheadline, design: .monospaced).weight(.bold))
                                        .foregroundStyle(Theme.inkMuted)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle.fill").font(.title2).foregroundStyle(Theme.voltInk)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Join \(room.hostName)'s room, code \(room.code)")
                    }
                }
            }
            .padding(Theme.gutter)
        }
        .clashBackground()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            browser.start()
            if let pending = app.pendingJoinCode {
                code = pending
                app.pendingJoinCode = nil
                joinByCode()
            }
        }
        .onDisappear { if app.session == nil { browser.stop() } }
        .onChange(of: browser.rooms) { _, _ in
            if waitingForCode, let room = browser.room(withCode: normalized) { join(room) }
        }
    }

    private func joinByCode() {
        guard RoomCode.isValid(normalized) else { return }
        codeFocused = false
        if let room = browser.room(withCode: normalized) {
            join(room)
        } else {
            waitingForCode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if waitingForCode {
                    waitingForCode = false
                    browser.error = "No room with code \(normalized) found nearby. Check the code and that you're near the host."
                }
            }
        }
    }

    private func join(_ room: NearbyRoom) {
        waitingForCode = false
        browser.error = nil
        app.join(room: room, browser: browser)
    }
}
