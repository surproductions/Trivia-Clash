import SwiftUI

@main
struct TriviaClashApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(app.preferences.appearance.colorScheme)
                .tint(Theme.voltInk)
                .onOpenURL { app.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.session?.resume() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if let error = app.bankError {
                ErrorStateView(title: "Something's missing", message: error, actionTitle: "Try again") { app.loadBank() }
            } else if app.bank == nil {
                LaunchView()
            } else if app.profile == nil {
                OnboardingView()
            } else {
                HomeView()
            }
        }
        .fullScreenCover(item: $app.session) { session in
            GameContainerView(session: session)
                .environmentObject(app)
                .preferredColorScheme(app.preferences.appearance.colorScheme)
        }
    }
}

struct LaunchView: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            Wordmark()
            ProgressView().tint(Theme.voltInk)
                .opacity(pulse ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clashBackground()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
        }
    }
}

struct ErrorStateView: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(title).font(.display(.title2)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.primary).padding(.top, 8)
            }
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clashBackground()
    }
}
