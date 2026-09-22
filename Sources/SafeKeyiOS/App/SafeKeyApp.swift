import SwiftUI
import SafeKeyCore

/// Refuses third-party keyboard extensions for the whole app, the way Apple's
/// own Passwords app does.
///
/// A custom keyboard is an app that sees every keystroke, and a vault is the
/// one place a typed seed phrase must not pass through someone else's code.
/// iOS only enforces the system keyboard by itself for secure fields, and a
/// multi-line seed editor cannot be one — so the app declines the extension
/// point outright and every field gets Apple's keyboard.
final class KeyboardPolicyDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier identifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        identifier != .keyboard
    }
}

@main
struct SafeKeyApp: App {
    @UIApplicationDelegateAdaptor(KeyboardPolicyDelegate.self) private var keyboardPolicy
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .noVault:
            OnboardingView()
        case .locked:
            LockScreenView()
        case .unlocked(let session):
            // iPad gets the sidebar layout the Passwords app uses there; a
            // compact width — every iPhone, and iPad slide-over — gets the
            // tile home screen. Driven by size class rather than device so
            // multitasking picks the right one on its own.
            // Either one picks up where the last session was: the model kept
            // the route, as identifiers, across the lock.
            let resume = model.resume.validated(in: session)
            if horizontalSizeClass == .regular {
                VaultSplitView(session: session, resume: resume)
            } else {
                VaultHomeView(session: session, resume: resume.homePath)
            }
        }
    }
}
