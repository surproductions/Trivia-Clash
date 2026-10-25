import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Wordmark(size: .title)
                .padding(.top, 24)
            TabView(selection: $page) {
                pitch(symbol: "timer", title: "Ten seconds.\nNo lookups.",
                      text: "Every question closes after 10 seconds — too fast to search the web or ask an assistant. Speed earns bonus points.")
                    .tag(0)
                pitch(symbol: "person.3.fill", title: "Play solo or\nwith the room.",
                      text: "Practise alone, or host a game and friends nearby join on their own phones with a 5-letter code. Free-for-all or teams.")
                    .tag(1)
                ProfileEditor(title: "Pick your name", buttonTitle: "Let's play") { name, avatar in
                    app.saveProfile(name: name, avatar: avatar)
                }
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            if page < 2 {
                Button("Next") { withAnimation { page += 1 } }
                    .buttonStyle(.primary)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 20)
            }
        }
        .clashBackground()
    }

    private func pitch(symbol: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Theme.voltInk)
                .accessibilityHidden(true)
            Text(title)
                .font(.display(.largeTitle))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(text)
                .font(.title3)
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
    }
}

/// Name + avatar picker used in onboarding and the profile screen.
struct ProfileEditor: View {
    let title: String
    let buttonTitle: String
    var initialName = ""
    var initialAvatar = Int.random(in: 0..<12)
    let onSave: (String, Int) -> Void

    @State private var name = ""
    @State private var avatar = 0
    @State private var loaded = false
    @FocusState private var nameFocused: Bool

    private var valid: Bool { Profile.isValid(name) }
    private var validationMessage: String? {
        let clean = Profile.clean(name)
        if clean.isEmpty { return nil }
        if clean.count < 2 { return "At least 2 characters." }
        if NameFilter.isBlocked(clean) { return "Please choose a different name." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.display(.title)).foregroundStyle(Theme.ink)
                HStack(spacing: 14) {
                    AvatarBadge(avatar: avatar, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Display name", text: $name)
                            .font(.label(.title3))
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($nameFocused)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceRaised))
                            .onChange(of: name) { _, value in
                                if value.count > 16 { name = String(value.prefix(16)) }
                            }
                            .accessibilityHint("2 to 16 characters, shown to other players")
                        Text(validationMessage ?? "Shown to other players. 2–16 characters.")
                            .font(.footnote)
                            .foregroundStyle(validationMessage == nil ? Theme.inkMuted : Theme.wrong)
                    }
                }
                SectionLabel(text: "Badge")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                    ForEach(0..<12, id: \.self) { i in
                        Button { avatar = i; Haptics.tap() } label: {
                            AvatarBadge(avatar: i, size: 44)
                                .overlay(Circle().stroke(Theme.ink, lineWidth: avatar == i ? 3 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Badge \(i + 1)")
                        .accessibilityAddTraits(avatar == i ? .isSelected : [])
                    }
                }
                Text("You play as a guest. Your name, badge and stats are stored only on this phone.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
                Button(buttonTitle) {
                    nameFocused = false
                    onSave(Profile.clean(name), avatar)
                }
                .buttonStyle(.primary)
                .disabled(!valid)
            }
            .padding(Theme.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = initialName
            avatar = initialAvatar
        }
    }
}
