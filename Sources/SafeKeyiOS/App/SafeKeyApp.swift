import SwiftUI
import SafeKeyCore

@main
struct SafeKeyApp: App {
    @State private var model = AppModel.forCurrentLaunch()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(model)
                    .task {
                        if case .loading = model.state { await model.bootstrap() }
                    }

                // Locking on `.background` is not enough on its own: iOS takes
                // the app-switcher snapshot around the transition, and the
                // switcher is where a shoulder-surfer looks. Covering from
                // `.inactive` means the snapshot can only ever contain this.
                if scenePhase != .active {
                    PrivacyCover()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: scenePhase)
            .onChange(of: scenePhase) { _, phase in
                // Leaving the foreground on a phone is the equivalent of
                // walking away from a desk.
                if phase == .background { model.lock() }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .noVault:
            OnboardingView()
        case .locked:
            LockScreenView()
        case .unlocked(let session):
            VaultListView(session: session)
        }
    }
}
